# Entrada: contexto publico descoberto pelos CLIs.
. as $c |
"Allow any-user to inspect objects in compartment id \($c.compartment_ocid) where all {request.principal.type = 'identityfederateddomainapp', request.principal.domain.id = '\($c.domain_ocid)', request.principal.ext_repository = '\($c.repository)', request.principal.ext_repository_id = '\($c.repository_id)', request.principal.ext_workflow_ref = '\($c.workflow_ref)', target.bucket.name = '\($c.bucket)'}"
