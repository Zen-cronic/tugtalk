# Separate read-only dashboard hosting

`deploy/dashboard_app.py` describes a separate Modal app, `comms-coach-dashboard`. It runs the Node gateway behind HTTPS with one container and no database volume. It adds only the explicit built-asset allowlist and the two gateway entrypoint modules to its image; it does not package the repository, local preview passwords or provider keys.

The manifest deliberately fixes `DASHBOARD_ALLOW_RECORDING_CHANGES=0` and `DASHBOARD_LOCAL_HTTP=0`. Browsers can review records and listen to/download kept audio; recording settings and deletion remain disabled. There are no model calls. The existing connector remains the authoritative store.

## Prepare and validate locally

Use the existing Python environment containing Modal; no new Python environment is needed. From the product repository:

```sh
npm run dashboard:build
npm run test:dashboard
npm test
```

In that configured Python environment:

```sh
python deploy/test_dashboard_manifest.py
```

The manifest tests use a fake Modal module and make no account or cloud calls. They check the image allowlist, read-only secure configuration and invalid-origin rejection. The manifest also compares each built asset with its source and refuses stale or missing output.

## Configuration to approve before deployment

Provision a separate Modal secret named `comms-coach-dashboard`, containing only:

- `DASHBOARD_CONNECTOR_TOKEN`: the credential for the intended account, preferably restricted to read scope.
- `DASHBOARD_PASSWORD`: a separate cryptographically random dashboard access code, at least 20 characters. Never reuse the connector token.

Create it through the provider's protected secret editor or an approved non-logging secret-provisioning flow. Do not place secret values in CLI arguments, source files, frontend variables or screenshots. Provisioning a new credential/secret and deploying the app are separate actions from preparing this manifest.

Set these nonsecret deployment variables:

| Variable | Required value |
|---|---|
| `DASHBOARD_ORIGIN` | The exact verified HTTPS browser origin for this dashboard endpoint, with no path |
| `DASHBOARD_UPSTREAM` | The exact existing connector HTTPS origin, with no path |

Do not guess a live endpoint host. Confirm the target workspace and endpoint naming before setting the origin. The gateway validates Host exactly and fails closed if the ingress or configured hostname differs. The `practice` web endpoint label belongs to the separate app; the existing connector deployment is untouched.

After deployment and secret provisioning are explicitly approved, the command in the configured Modal environment is:

```sh
poetry run modal deploy deploy/dashboard_app.py
```

Pass the two public origins through the command environment. The manifest references the named secret without embedding its values. It does not enable recording writes or keep a container permanently warm.

## Runtime behavior and live acceptance

The manifest uses 0.25 CPU, 512 MiB, `max_containers=1`, `min_containers=0`, an idle window of 300 seconds, a 60-second function timeout and at most eight concurrent inputs. The container can scale down, preempt or restart; its in-memory sessions then expire and users sign in again. This is a single-account private dashboard, not durable multiuser identity. Do not increase the replica count without redesigning sessions and throttling. These limits are configuration, not a measured cost or availability guarantee.

Before using real data in a demo, verify the exact public Host passes ingress; HTTP is redirected by the platform to HTTPS; cookies have Secure/HttpOnly/SameSite=Strict; anonymous API reads fail; logout invalidates the session; raw connector credentials are absent from browser traffic; and recording mutation routes remain disabled. With an authorized read-only account, compare a new saved practice and request version against the other devices. Test a revoked upstream token and sign-in after a gateway restart. Check startup/idle behavior within the approved hosting budget. Never make a private account publicly accessible for these checks.

No deployment, secret creation, domain configuration or personal-account change is performed by the offline tests. A successful local manifest import is not live ingress, billing or security validation.

Official implementation references: [Modal web_server](https://modal.com/docs/reference/modal.web_server), [Web Functions](https://modal.com/docs/guide/webhooks), and [Secrets](https://modal.com/docs/guide/secrets).
