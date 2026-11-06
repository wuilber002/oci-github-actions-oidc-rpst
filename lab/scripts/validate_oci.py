"""GitHub OIDC -> OAuth-authenticated OCI RPST -> Object Storage ListObjects."""
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import oci
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def request_json(opener, request, stage):
    try:
        with opener.open(request, timeout=45) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        sys.exit(f"{stage}: HTTP {exc.code}. Confira a configuracao e a auditoria OCI.")
    except Exception:
        sys.exit(f"{stage}: falha de conexao ou resposta invalida; detalhes omitidos.")


def main():
    required = (
        "OCI_REGION", "OCI_DOMAIN_URL", "OCI_CLIENT_ID", "OCI_CLIENT_SECRET",
        "OCI_NAMESPACE", "OCI_BUCKET", "EXPECTED_REPOSITORY", "EXPECTED_BRANCH",
        "OIDC_AUDIENCE", "OCI_RES_TYPE", "ACTIONS_ID_TOKEN_REQUEST_URL",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    )
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        sys.exit("Variaveis ausentes: " + ", ".join(missing))
    if os.environ.get("GITHUB_REPOSITORY") != os.environ["EXPECTED_REPOSITORY"]:
        sys.exit("Repositorio diferente do configurado.")
    if os.environ.get("GITHUB_REF") != "refs/heads/" + os.environ["EXPECTED_BRANCH"]:
        sys.exit("Branch diferente da autorizada.")
    domain = os.environ["OCI_DOMAIN_URL"].rstrip("/")
    parsed = urllib.parse.urlsplit(domain)
    if (parsed.scheme != "https" or not parsed.hostname
            or not parsed.hostname.endswith(".identity.oraclecloud.com")
            or parsed.username or parsed.password or parsed.path
            or parsed.query or parsed.fragment or parsed.port not in (None, 443)):
        sys.exit("OCI_DOMAIN_URL invalida para OCI comercial.")
    opener = urllib.request.build_opener(NoRedirect())
    url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"]
    url += ("&" if "?" in url else "?") + urllib.parse.urlencode({
        "audience": os.environ["OIDC_AUDIENCE"]
    })
    jwt = request_json(opener, urllib.request.Request(url, headers={
        "Authorization": "Bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]
    }), "Solicitacao OIDC").get("value")
    if not isinstance(jwt, str) or not jwt:
        sys.exit("GitHub nao retornou um JWT.")
    print("::add-mask::" + jwt, flush=True)
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_der = private_key.public_key().public_bytes(
        serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    credentials = base64.b64encode((os.environ["OCI_CLIENT_ID"] + ":"
        + os.environ["OCI_CLIENT_SECRET"]).encode()).decode()
    print("::add-mask::" + credentials, flush=True)
    payload = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "requested_token_type": "urn:oci:token-type:oci-rpst",
        "subject_token_type": "jwt",
        "subject_token": jwt,
        "public_key": base64.b64encode(public_der).decode(),
        "res_type": os.environ["OCI_RES_TYPE"],
        "rpst_exp": "20",
    }).encode()
    rpst = request_json(opener, urllib.request.Request(
        domain + "/oauth2/v1/token", data=payload, headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Authorization": "Basic " + credentials,
        }), "Troca JWT por RPST").get("token")
    if not isinstance(rpst, str) or not rpst or rpst.count(".") != 2:
        sys.exit("OCI nao retornou um RPST JWT valido na resposta.")
    print("::add-mask::" + rpst, flush=True)
    print("Troca JWT por RPST concluida.")
    signer = oci.auth.signers.SecurityTokenSigner(rpst, private_key)
    client = oci.object_storage.ObjectStorageClient(
        config={"region": os.environ["OCI_REGION"]}, signer=signer, timeout=(10, 45))
    try:
        response = client.list_objects(namespace_name=os.environ["OCI_NAMESPACE"],
            bucket_name=os.environ["OCI_BUCKET"], limit=10)
    except oci.exceptions.ServiceError as exc:
        code = re.sub(r"[^A-Za-z0-9_.-]", "", str(exc.code))
        sys.exit(f"ListObjects: HTTP {exc.status}, codigo {code}. Confira policy, bucket e namespace.")
    except Exception:
        sys.exit("Falha ao chamar Object Storage; detalhes omitidos.")
    print("Acesso OCI validado: ListObjects retornou HTTP " + str(response.status))
    print("Objetos nesta pagina: " + str(len(response.data.objects)))


if __name__ == "__main__":
    main()
