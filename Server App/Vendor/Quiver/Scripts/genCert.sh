openssl ecparam -name prime256v1 -genkey -noout -out localCA.key
openssl req -x509 -new -key localCA.key -sha256 -days 7 \
  -subj "/CN=Local Dev CA" -out localCA.crt

# 2) Server key + CSR (EC P-256)
openssl ecparam -name prime256v1 -genkey -noout -out localhost.key
openssl req -new -key localhost.key -subj "/CN=localhost" -out localhost.csr

# 3) Sign with SANs + serverAuth
cat > localhost.ext <<'EOF'
subjectAltName=DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
EOF

openssl x509 -req -in localhost.csr -CA localCA.crt -CAkey localCA.key \
  -CAcreateserial -out localhost.crt -days 7 -sha256 -extfile localhost.ext
