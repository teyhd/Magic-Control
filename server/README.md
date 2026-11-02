# Windows Python backend

The FastAPI companion service in `magic_server.py` provides the local Windows keyboard and pointer actions consumed by the Watch app. Install `requirements.txt` into an isolated environment. Set `MAGIC_CONTROL_TOKEN` to a locally managed nonempty bearer token before starting the service, and configure the Watch client to match it. The publication copy requires this environment variable instead of an embedded configuration value.

Review host binding and allowed actions before running. This source publication does not start the server or control the desktop. Logs, credentials, environments, and generated files are excluded; the Watch application source is preserved.
