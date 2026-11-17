# Tailwind cloud probe (dormant)

The Tailwind public v2 API has **no door activity feed**:

- `/notifications?limit=10` → "The feature has been discontinued."
- `/devices/<id>/events` → only `connections` and `faults`
- `/logs` → empty
- `/doors`, `/events`, `/activity`, `/history`, `/timeline`, `/user/activity` → 404

The app's 30-day activity log is not in the public API; it is mobile/MQTT-only. Without an app
capture (HTTP Toolkit) there is no auto-open vs manual label available. The local equivalent is the
UniFi Protect **Garage camera vehicle** event, which is what the arrival trigger uses.

The service is in the automation-pollers compose under `profiles: ["probe"]`, so it does not run on
deploy. Run it manually only after capturing the real activity endpoint:

    docker compose --profile probe run --rm tailwind-cloud
