# RFC 9114: HTTP/3 技術仕様書

> **RFC 9114** - HTTP/3
> **発行**: 2022年6月
> **ステータス**: Proposed Standard
> **関連RFC**: RFC 9000 (QUIC), RFC 9001 (QUIC-TLS), RFC 9110 (HTTP Semantics)

---

## 1. 概要

### 1.1 HTTP/3とは

HTTP/3は、QUICトランスポートプロトコル上でHTTPセマンティクスをマッピングする次世代HTTPプロトコルです。

```
┌─────────────────────────────────────────┐
│            HTTP/3 (RFC 9114)            │
│    リクエスト/レスポンス、フレーミング     │
├─────────────────────────────────────────┤
│            QPACK (RFC 9204)             │
│           ヘッダー圧縮                   │
├─────────────────────────────────────────┤
│            QUIC (RFC 9000)              │
│  ストリーム多重化、フロー制御、再送制御    │
├─────────────────────────────────────────┤
│           TLS 1.3 (RFC 8446)            │
│            暗号化、認証                  │
├─────────────────────────────────────────┤
│               UDP                        │
└─────────────────────────────────────────┘
```

### 1.2 HTTP/3の利点

| 特徴 | HTTP/2 (TCP) | HTTP/3 (QUIC) |
|------|-------------|---------------|
| Head-of-Line Blocking | TCP層で発生 | ストリーム単位で解消 |
| 接続確立 | TCP + TLS = 2-3 RTT | 1 RTT (0-RTT可能) |
| パケットロス回復 | 全ストリームに影響 | 影響ストリームのみ |
| 接続マイグレーション | 不可 | 可能 |

### 1.3 プロトコルの関係

```
HTTP Semantics (RFC 9110)
         │
         ├──→ HTTP/1.1 (RFC 9112) → TCP
         │
         ├──→ HTTP/2 (RFC 9113) → TCP + TLS
         │
         └──→ HTTP/3 (RFC 9114) → QUIC (UDP + TLS 1.3)
```

---

## 2. 接続の確立と管理

### 2.1 接続の発見

クライアントはHTTP/3エンドポイントを以下の方法で発見します：

1. **Alt-Svc ヘッダー**: `Alt-Svc: h3=":443"`
2. **Alt-Svc フレーム** (HTTP/2経由)
3. **DNS HTTPS レコード**: `_https._tcp.example.com`
4. **直接接続**: 既知のHTTP/3サーバーへの接続

### 2.2 ALPN識別子

```
ALPN: "h3"
```

HTTP/3は `h3` をALPN (Application-Layer Protocol Negotiation) 識別子として使用します。

### 2.3 接続確立フロー

```
Client                                    Server
   │                                         │
   │─────── QUIC Initial (ClientHello) ─────→│
   │                                         │
   │←────── QUIC Initial (ServerHello) ──────│
   │←────── QUIC Handshake ──────────────────│
   │                                         │
   │─────── QUIC Handshake (Finished) ──────→│
   │                                         │
   │═══════ 1-RTT Keys Available ════════════│
   │                                         │
   │─────── Control Stream (SETTINGS) ──────→│
   │←────── Control Stream (SETTINGS) ───────│
   │                                         │
   │═══════ HTTP/3 Ready ════════════════════│
```

### 2.4 SETTINGS フレーム

接続確立後、各エンドポイントは**必ず**制御ストリーム上でSETTINGSフレームを送信する必要があります。

```
SETTINGS Frame {
  Type (i) = 0x04,
  Length (i),
  Setting (..) ...,
}

Setting {
  Identifier (i),
  Value (i),
}
```

**定義済み設定パラメータ:**

| 識別子 | 名前 | 説明 |
|--------|------|------|
| 0x06 | SETTINGS_MAX_FIELD_SECTION_SIZE | フィールドセクションの最大サイズ |
| 0x01 | SETTINGS_QPACK_MAX_TABLE_CAPACITY | QPACK動的テーブル容量 |
| 0x07 | SETTINGS_QPACK_BLOCKED_STREAMS | ブロック可能ストリーム数 |

---

## 3. ストリームの種類

### 3.1 ストリーム概要

HTTP/3はQUICストリームを以下のように使用します：

```
┌──────────────────────────────────────────────────────┐
│                  QUIC Streams                        │
├─────────────────────────┬────────────────────────────┤
│  Bidirectional Streams  │   Unidirectional Streams   │
│      (双方向)            │       (単方向)              │
├─────────────────────────┼────────────────────────────┤
│  Request Streams        │  Control Stream (0x00)     │
│  (クライアント開始)       │  Push Stream (0x01)        │
│                         │  QPACK Encoder (0x02)      │
│                         │  QPACK Decoder (0x03)      │
└─────────────────────────┴────────────────────────────┘
```

### 3.2 リクエストストリーム (双方向)

- **開始者**: クライアントのみ
- **用途**: 単一のHTTPリクエスト/レスポンス交換
- **ストリームID**: 0, 4, 8, 12, ... (4の倍数)

```
Client                                    Server
   │                                         │
   │──── Request Stream (ID=0) ─────────────→│
   │     HEADERS (リクエスト)                  │
   │     DATA (ボディ)                        │
   │     FIN                                 │
   │                                         │
   │←─── Request Stream (ID=0) ──────────────│
   │     HEADERS (レスポンス)                  │
   │     DATA (ボディ)                        │
   │     FIN                                 │
```

### 3.3 制御ストリーム (単方向)

- **ストリームタイプ**: 0x00
- **開始者**: 各エンドポイントが1つずつ
- **用途**: 接続レベルのフレーム送信
- **重要**: クローズは接続エラー (H3_CLOSED_CRITICAL_STREAM)

```
Control Stream {
  Stream Type (i) = 0x00,
  SETTINGS Frame,
  [GOAWAY Frame],
  [MAX_PUSH_ID Frame],
  [CANCEL_PUSH Frame ...],
}
```

### 3.4 プッシュストリーム (単方向)

- **ストリームタイプ**: 0x01
- **開始者**: サーバーのみ
- **用途**: プッシュされたレスポンスの配信

```
Push Stream {
  Stream Type (i) = 0x01,
  Push ID (i),
  HEADERS Frame,
  [DATA Frame ...],
  [HEADERS Frame (trailers)],
}
```

### 3.5 QPACKストリーム (単方向)

**エンコーダーストリーム** (タイプ 0x02):
- 動的テーブル更新の送信

**デコーダーストリーム** (タイプ 0x03):
- テーブル更新の確認応答

---

## 4. フレーム形式

### 4.1 フレーム構造

すべてのHTTP/3フレームは以下の形式に従います：

```
HTTP/3 Frame {
  Type (i),
  Length (i),
  Frame Payload (..),
}
```

- **Type**: 可変長整数 (フレームタイプ)
- **Length**: 可変長整数 (ペイロード長)
- **Frame Payload**: フレーム固有のデータ

### 4.2 フレームタイプ一覧

| タイプ | 名前 | 許可されるストリーム |
|--------|------|---------------------|
| 0x00 | DATA | リクエスト、プッシュ |
| 0x01 | HEADERS | リクエスト、プッシュ |
| 0x03 | CANCEL_PUSH | 制御のみ |
| 0x04 | SETTINGS | 制御のみ |
| 0x05 | PUSH_PROMISE | リクエストのみ |
| 0x07 | GOAWAY | 制御のみ |
| 0x0d | MAX_PUSH_ID | 制御のみ |

### 4.3 DATA フレーム

```
DATA Frame {
  Type (i) = 0x00,
  Length (i),
  Data (..),
}
```

HTTPメッセージのコンテンツ（ボディ）を運搬します。

### 4.4 HEADERS フレーム

```
HEADERS Frame {
  Type (i) = 0x01,
  Length (i),
  Encoded Field Section (..),
}
```

QPACKでエンコードされたHTTPヘッダーフィールドを含みます。

### 4.5 SETTINGS フレーム

```
SETTINGS Frame {
  Type (i) = 0x04,
  Length (i),
  Setting (..) ...,
}
```

**重要な制約**:
- 制御ストリームの最初のフレームでなければならない
- 接続中に1回のみ送信可能
- 受信前にリクエストを送信してはならない

### 4.6 PUSH_PROMISE フレーム

```
PUSH_PROMISE Frame {
  Type (i) = 0x05,
  Length (i),
  Push ID (i),
  Encoded Field Section (..),
}
```

サーバーがプッシュするリソースをアナウンスします。

### 4.7 GOAWAY フレーム

```
GOAWAY Frame {
  Type (i) = 0x07,
  Length (i),
  Stream ID/Push ID (i),
}
```

接続のグレースフルシャットダウンを開始します。

### 4.8 MAX_PUSH_ID フレーム

```
MAX_PUSH_ID Frame {
  Type (i) = 0x0d,
  Length (i),
  Push ID (i),
}
```

クライアントがサーバーに許可する最大プッシュIDを設定します。

### 4.9 CANCEL_PUSH フレーム

```
CANCEL_PUSH Frame {
  Type (i) = 0x03,
  Length (i),
  Push ID (i),
}
```

プッシュをキャンセルします。

---

## 5. HTTPリクエスト/レスポンス

### 5.1 メッセージ構造

```
HTTP Message {
  Header Section (HEADERS frame),
  [Content (DATA frames)],
  [Trailer Section (HEADERS frame)],
}
```

### 5.2 疑似ヘッダーフィールド

**リクエスト疑似ヘッダー:**

| フィールド | 必須 | 説明 |
|-----------|------|------|
| :method | Yes | HTTPメソッド |
| :scheme | Yes | スキーム (http/https) |
| :authority | No* | ホスト情報 |
| :path | Yes* | リクエストパス |

*CONNECT メソッドでは異なるルール

**レスポンス疑似ヘッダー:**

| フィールド | 必須 | 説明 |
|-----------|------|------|
| :status | Yes | HTTPステータスコード |

### 5.3 リクエスト例

```
:method = GET
:scheme = https
:authority = example.com
:path = /index.html
user-agent = Mozilla/5.0
accept = text/html
```

### 5.4 レスポンス例

```
:status = 200
content-type = text/html
content-length = 1234

[DATA: <html>...</html>]
```

### 5.5 フィールド名のルール

- フィールド名は**小文字**でなければならない
- 大文字は不正なリクエスト/レスポンスとして扱う
- 疑似ヘッダーは通常ヘッダーより前に配置

---

## 6. サーバープッシュ

### 6.1 プッシュの流れ

```
Client                                    Server
   │                                         │
   │──── Request: GET /page.html ───────────→│
   │                                         │
   │←─── PUSH_PROMISE (Push ID=0) ───────────│
   │     /style.css                          │
   │                                         │
   │←─── PUSH_PROMISE (Push ID=1) ───────────│
   │     /script.js                          │
   │                                         │
   │←─── Response: /page.html ───────────────│
   │                                         │
   │←─── Push Stream (ID=0): /style.css ─────│
   │←─── Push Stream (ID=1): /script.js ─────│
```

### 6.2 プッシュID管理

1. クライアントは`MAX_PUSH_ID`でプッシュを許可
2. サーバーは0から順番にプッシュIDを割り当て
3. プッシュIDは`MAX_PUSH_ID`を超えてはならない

### 6.3 プッシュの制約

プッシュ可能なリクエストは以下を満たす必要があります：

- キャッシュ可能であること
- 安全なメソッド（GET, HEAD）であること
- リクエストコンテンツを含まないこと

### 6.4 プッシュのキャンセル

```
// クライアントがプッシュを拒否
CANCEL_PUSH { Push ID = 0 }

// または、プッシュストリームをRSTで閉じる
RESET_STREAM { Stream ID = ..., Error = H3_REQUEST_CANCELLED }
```

---

## 7. エラー処理

### 7.1 エラーコード

| コード | 名前 | 説明 |
|--------|------|------|
| 0x0100 | H3_NO_ERROR | 正常終了 |
| 0x0101 | H3_GENERAL_PROTOCOL_ERROR | 一般的なプロトコルエラー |
| 0x0102 | H3_INTERNAL_ERROR | 内部エラー |
| 0x0103 | H3_STREAM_CREATION_ERROR | 不正なストリーム作成 |
| 0x0104 | H3_CLOSED_CRITICAL_STREAM | 重要ストリームのクローズ |
| 0x0105 | H3_FRAME_UNEXPECTED | 予期しないフレーム |
| 0x0106 | H3_FRAME_ERROR | フレーム形式エラー |
| 0x0107 | H3_EXCESSIVE_LOAD | 過剰な負荷 |
| 0x0108 | H3_ID_ERROR | ID関連エラー |
| 0x0109 | H3_SETTINGS_ERROR | 設定エラー |
| 0x010a | H3_MISSING_SETTINGS | SETTINGS未受信 |
| 0x010b | H3_REQUEST_REJECTED | リクエスト拒否 |
| 0x010c | H3_REQUEST_CANCELLED | リクエストキャンセル |
| 0x010d | H3_REQUEST_INCOMPLETE | リクエスト不完全 |
| 0x010e | H3_MESSAGE_ERROR | メッセージ形式エラー |
| 0x010f | H3_CONNECT_ERROR | CONNECT失敗 |
| 0x0110 | H3_VERSION_FALLBACK | バージョンフォールバック |

### 7.2 ストリームエラー vs 接続エラー

**ストリームエラー** (RESET_STREAM):
- 単一ストリームにのみ影響
- 他のストリームは継続可能

**接続エラー** (CONNECTION_CLOSE):
- 接続全体を終了
- H3_CLOSED_CRITICAL_STREAM など

### 7.3 不正なメッセージの検出

以下は不正なメッセージとして扱われます：

- 大文字のフィールド名
- 必須疑似ヘッダーの欠落
- 不正な疑似ヘッダー値
- 通常ヘッダー後の疑似ヘッダー
- 無効な文字シーケンス
- Content-Length不一致

---

## 8. セキュリティ考慮事項

### 8.1 暗号化

HTTP/3は常にTLS 1.3で保護されます（QUICの要件）。

```
すべてのHTTP/3トラフィックは暗号化される
   ↓
中間者による盗聴・改ざん防止
   ↓
証明書による相互認証
```

### 8.2 ヘッダー圧縮攻撃 (CRIME/BREACH)

QPACKはHPACKと同様の圧縮攻撃に脆弱です。

**緩和策**:
- センシティブなヘッダーは圧縮しない
- 動的テーブルのサイズを制限
- 同一オリジンポリシーの厳守

### 8.3 DoS攻撃対策

| 攻撃ベクトル | 対策 |
|-------------|------|
| 大量ストリーム | QUIC MAX_STREAMS制限 |
| 巨大ヘッダー | SETTINGS_MAX_FIELD_SECTION_SIZE |
| 大量プッシュ | MAX_PUSH_ID制限 |
| 不明フレーム | 無視または制限 |

### 8.4 0-RTTのリスク

0-RTTデータはリプレイ攻撃に脆弱です。

**対策**:
- 冪等でないリクエストは0-RTTで送信しない
- サーバー側でリプレイ検出を実装
- At-Most-Once配信の保証

### 8.5 接続マイグレーション

クライアントIPアドレスが変更される可能性があります。

**考慮事項**:
- IPベースのレート制限の再評価
- ジオロケーションベースのアクセス制御
- セッション継続性の検証

---

## 9. HTTP/2との比較

### 9.1 主な違い

| 項目 | HTTP/2 | HTTP/3 |
|------|--------|--------|
| トランスポート | TCP | QUIC (UDP) |
| 暗号化 | オプション | 必須 |
| ヘッダー圧縮 | HPACK | QPACK |
| 多重化 | TCPの制約あり | 完全な多重化 |
| 優先度 | 明示的シグナル | 削除（拡張で対応） |
| ストリームID | 31ビット | 62ビット |
| フロー制御 | HTTP/2独自 | QUICに委譲 |
| SETTINGS | 更新可能 | 1回のみ |

### 9.2 互換性のないフレーム

以下のHTTP/2フレームはHTTP/3に存在しません：

- PRIORITY → 削除（Extensible Priorities拡張で代替）
- PING → QUICレベルで処理
- WINDOW_UPDATE → QUICフロー制御で代替
- CONTINUATION → 不要（QUICストリームで処理）

### 9.3 移行の考慮事項

```
HTTP/2 → HTTP/3 移行チェックリスト:

□ QUICスタックの実装/統合
□ HPACKからQPACKへの移行
□ 優先度処理の見直し
□ フロー制御ロジックの簡素化
□ エラーコードのマッピング
□ サーバープッシュの調整
```

---

## 10. 実装ガイドライン

### 10.1 最小実装要件

```swift
// 必須コンポーネント
protocol HTTP3Connection {
    func openRequestStream() async throws -> HTTP3Stream
    func acceptPushStream() async throws -> HTTP3Stream

    var controlStream: HTTP3ControlStream { get }
    var settings: HTTP3Settings { get }
}

protocol HTTP3Stream {
    func sendHeaders(_ headers: HPACKHeaders) async throws
    func sendData(_ data: Data) async throws
    func receiveHeaders() async throws -> HPACKHeaders
    func receiveData() async throws -> Data
}
```

### 10.2 推奨設定

```swift
struct HTTP3Configuration {
    // 最小100同時リクエストストリームを許可
    var maxConcurrentStreams: UInt64 = 100

    // ヘッダーサイズ制限 (16KB推奨)
    var maxFieldSectionSize: UInt64 = 16384

    // QPACK動的テーブル (4KB推奨)
    var qpackMaxTableCapacity: UInt64 = 4096

    // ブロック可能ストリーム数
    var qpackBlockedStreams: UInt64 = 100
}
```

### 10.3 エラーハンドリングパターン

```swift
enum HTTP3Error: Error {
    case protocolError(HTTP3ErrorCode)
    case streamError(HTTP3ErrorCode, streamID: UInt64)
    case connectionError(HTTP3ErrorCode)
    case malformedMessage(String)
}

func handleFrame(_ frame: HTTP3Frame, on stream: HTTP3Stream) throws {
    switch frame {
    case .data(let data):
        guard stream.headersReceived else {
            throw HTTP3Error.protocolError(.frameUnexpected)
        }
        // Process data

    case .headers(let headers):
        try validateHeaders(headers)
        // Process headers

    default:
        // Unknown frames MUST be ignored
        break
    }
}
```

---

## 11. 参考資料

### 関連RFC

- **RFC 9000**: QUIC: A UDP-Based Multiplexed and Secure Transport
- **RFC 9001**: Using TLS to Secure QUIC
- **RFC 9002**: QUIC Loss Detection and Congestion Control
- **RFC 9110**: HTTP Semantics
- **RFC 9204**: QPACK: Field Compression for HTTP/3

### 公式リソース

- [IETF QUIC Working Group](https://quicwg.org/)
- [HTTP/3 Explained (curl)](https://http3-explained.haxx.se/)

---

**Document Version**: 1.0
**Last Updated**: 2026-01-19
**Based on**: RFC 9114 (June 2022)
