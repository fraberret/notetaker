#!/bin/zsh
# Crea (una volta sola) un certificato di firma locale "Notetaker locale" nel portachiavi di login.
# Serve a firmare l'app sempre con la stessa identità, così macOS non richiede i permessi
# (Accessibilità, Microfono, Registrazione schermo) a ogni ricompilazione.
# Facoltativo: senza certificato app/build.sh firma ad hoc e funziona lo stesso.
set -euo pipefail
NOME="Notetaker locale"
PORTACHIAVI="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$PORTACHIAVI" 2>/dev/null | grep -q "\"$NOME\""; then
  echo "Il certificato \"$NOME\" c'è già."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NOME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# LibreSSL di sistema: il .p12 che produce è leggibile da "security import".
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/chiave.pem" -out "$TMP/cert.pem" 2>/dev/null
PW="notetaker-$RANDOM$RANDOM"
/usr/bin/openssl pkcs12 -export -inkey "$TMP/chiave.pem" -in "$TMP/cert.pem" \
  -name "$NOME" -out "$TMP/cert.p12" -passout "pass:$PW"

security import "$TMP/cert.p12" -k "$PORTACHIAVI" -P "$PW" -T /usr/bin/codesign
echo "Ora macOS chiede la password del Mac per rendere affidabile il certificato per la firma."
security add-trusted-cert -r trustRoot -p codeSign -k "$PORTACHIAVI" "$TMP/cert.pem"

if security find-identity -p codesigning "$PORTACHIAVI" | grep -q "\"$NOME\""; then
  echo "Certificato \"$NOME\" pronto."
else
  echo "Certificato importato ma non valido per la firma: controlla Accesso Portachiavi." >&2
  exit 1
fi
