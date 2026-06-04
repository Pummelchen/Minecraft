import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Instant;
import java.util.Arrays;

public final class AddPummelchenServer {
    private static final byte TAG_END = 0;
    private static final byte TAG_BYTE = 1;
    private static final byte TAG_STRING = 8;
    private static final byte TAG_LIST = 9;
    private static final byte TAG_COMPOUND = 10;

    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            throw new IllegalArgumentException("usage: AddPummelchenServer <minecraft-dir> <server-name> <server-address>");
        }
        Path minecraftDir = Path.of(args[0]);
        String serverName = args[1];
        String serverAddress = args[2];
        Files.createDirectories(minecraftDir);

        Path serversDat = minecraftDir.resolve("servers.dat");
        byte[] next;
        if (Files.exists(serversDat)) {
            byte[] existing = Files.readAllBytes(serversDat);
            if (new String(existing, java.nio.charset.StandardCharsets.ISO_8859_1).contains(serverAddress)) {
                System.out.println("Pummelchen server entry already exists.");
                return;
            }
            backup(serversDat);
            try {
                next = appendServer(existing, serverName, serverAddress);
            } catch (RuntimeException ex) {
                next = singleServerFile(serverName, serverAddress);
            }
        } else {
            next = singleServerFile(serverName, serverAddress);
        }
        Files.write(serversDat, next);
        System.out.println("Pummelchen server entry is ready.");
    }

    private static void backup(Path file) throws IOException {
        String stamp = Instant.now().toString().replace(":", "").replace(".", "");
        Files.copy(file, file.resolveSibling("servers.dat.pummelchen-backup-" + stamp), StandardCopyOption.REPLACE_EXISTING);
    }

    private static byte[] appendServer(byte[] data, String name, String ip) throws IOException {
        Cursor cursor = new Cursor(data);
        if (cursor.u8() != TAG_COMPOUND) {
            throw new IllegalArgumentException("root is not a compound");
        }
        cursor.utf();
        while (cursor.pos < data.length) {
            int tagStart = cursor.pos;
            int type = cursor.u8();
            if (type == TAG_END) {
                break;
            }
            String tagName = cursor.utf();
            int payloadStart = cursor.pos;
            if (type == TAG_LIST && "servers".equals(tagName)) {
                int childType = cursor.u8();
                int countPos = cursor.pos;
                int count = cursor.i32();
                int compoundsStart = cursor.pos;
                if (childType != TAG_COMPOUND || count < 0) {
                    throw new IllegalArgumentException("servers list is not a compound list");
                }
                for (int i = 0; i < count; i++) {
                    skipCompoundPayload(cursor);
                }
                int compoundsEnd = cursor.pos;
                ByteArrayOutputStream out = new ByteArrayOutputStream(data.length + 256);
                out.write(data, 0, countPos);
                writeInt(out, count + 1);
                out.write(data, compoundsStart, compoundsEnd - compoundsStart);
                out.write(serverCompound(name, ip));
                out.write(data, compoundsEnd, data.length - compoundsEnd);
                return out.toByteArray();
            }
            cursor.pos = payloadStart;
            skipPayload(cursor, type);
        }
        return singleServerFile(name, ip);
    }

    private static byte[] singleServerFile(String name, String ip) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(256);
        DataOutputStream data = new DataOutputStream(out);
        data.writeByte(TAG_COMPOUND);
        data.writeUTF("");
        data.writeByte(TAG_LIST);
        data.writeUTF("servers");
        data.writeByte(TAG_COMPOUND);
        data.writeInt(1);
        data.write(serverCompound(name, ip));
        data.writeByte(TAG_END);
        data.flush();
        return out.toByteArray();
    }

    private static byte[] serverCompound(String name, String ip) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(192);
        DataOutputStream data = new DataOutputStream(out);
        data.writeByte(TAG_STRING);
        data.writeUTF("name");
        data.writeUTF(name);
        data.writeByte(TAG_STRING);
        data.writeUTF("ip");
        data.writeUTF(ip);
        data.writeByte(TAG_BYTE);
        data.writeUTF("acceptTextures");
        data.writeByte(1);
        data.writeByte(TAG_BYTE);
        data.writeUTF("hideAddress");
        data.writeByte(0);
        data.writeByte(TAG_END);
        data.flush();
        return out.toByteArray();
    }

    private static void skipCompoundPayload(Cursor cursor) {
        while (cursor.pos < cursor.data.length) {
            int type = cursor.u8();
            if (type == TAG_END) {
                return;
            }
            cursor.utf();
            skipPayload(cursor, type);
        }
        throw new IllegalArgumentException("unterminated compound");
    }

    private static void skipPayload(Cursor cursor, int type) {
        switch (type) {
            case 1 -> cursor.skip(1);
            case 2 -> cursor.skip(2);
            case 3, 5 -> cursor.skip(4);
            case 4, 6 -> cursor.skip(8);
            case 7 -> cursor.skip(cursor.i32());
            case 8 -> cursor.utf();
            case 9 -> {
                int childType = cursor.u8();
                int count = cursor.i32();
                if (count < 0) {
                    throw new IllegalArgumentException("negative list size");
                }
                for (int i = 0; i < count; i++) {
                    skipPayload(cursor, childType);
                }
            }
            case 10 -> skipCompoundPayload(cursor);
            case 11 -> cursor.skip(Math.multiplyExact(cursor.i32(), 4));
            case 12 -> cursor.skip(Math.multiplyExact(cursor.i32(), 8));
            default -> throw new IllegalArgumentException("unknown NBT tag " + type);
        }
    }

    private static void writeInt(ByteArrayOutputStream out, int value) {
        out.write((value >>> 24) & 0xff);
        out.write((value >>> 16) & 0xff);
        out.write((value >>> 8) & 0xff);
        out.write(value & 0xff);
    }

    private static final class Cursor {
        final byte[] data;
        int pos;

        Cursor(byte[] data) {
            this.data = data;
        }

        int u8() {
            require(1);
            return data[pos++] & 0xff;
        }

        int i32() {
            require(4);
            int value = ((data[pos] & 0xff) << 24)
                | ((data[pos + 1] & 0xff) << 16)
                | ((data[pos + 2] & 0xff) << 8)
                | (data[pos + 3] & 0xff);
            pos += 4;
            return value;
        }

        String utf() {
            require(2);
            int len = ((data[pos] & 0xff) << 8) | (data[pos + 1] & 0xff);
            pos += 2;
            require(len);
            String value = new String(Arrays.copyOfRange(data, pos, pos + len), java.nio.charset.StandardCharsets.UTF_8);
            pos += len;
            return value;
        }

        void skip(int count) {
            if (count < 0) {
                throw new IllegalArgumentException("negative skip");
            }
            require(count);
            pos += count;
        }

        void require(int count) {
            if (pos + count > data.length) {
                throw new IllegalArgumentException("truncated NBT");
            }
        }
    }
}
