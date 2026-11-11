# UniFi Controller and UniFi Outlet (v1.0.0, untested on hardware)

Two self-written drivers that expose UniFi power outlets (USP PDU Pro, USP Plug) to Control4 as on/off relays.

- `UniFi_Controller.c4z` (parent): logs in, polls outlets, serves children, web view page on binding 5001.
- `UniFi_Outlet.c4z` (child): one relay per outlet, relay proxy on binding 5001, bound to the parent over connection 1.

## Setup

1. On the UniFi console, create a local admin account for Control4. A Viewer role cannot switch outlets.
2. Add a **UniFi Controller** driver. Set Host, Username and Password. Leave Controller Type on Auto.
3. Add one **UniFi Outlet** per outlet. Bind its **UniFi Controller** connection to the parent.
4. Copy the `Device ID:Outlet Index` key for each outlet from the parent's **Discovered Outlets** property, then enter Device ID and Outlet Index on the child.
5. Web view: a page-address change needs a Director reboot. Proxy changes need delete and re-add.

Turning an outlet OFF from the web page asks for confirmation. Opening, refreshing or reconnecting the page never switches anything.

## Known gaps

- Child drop-downs are typed fields, not drop-downs. The dynamic list-fill call is not verified in this repo.
- Power-cycle is not implemented (TODO in code).

## Unverified assumptions (check on first real run; raw responses are logged at Debug level)

- Login: `POST /api/auth/login` (UniFi OS) with fallback `POST /api/login` (legacy). Session comes from `Set-Cookie` (TOKEN / unifises), CSRF from `X-CSRF-Token` or `X-Updated-CSRF-Token`.
- Read: `GET /proxy/network/api/s/<site>/stat/device` (legacy without the prefix). Power devices are detected by `outlet_table` / `outlet_overrides` entries or model USPPDUP / USPPLUG.
- Outlet state from `relay_state`. Names from `outlet_overrides` then `outlet_table`. USP Plug fallback: index 1 from top-level `relay_state` when no outlet arrays exist.
- Write: `PUT /proxy/network/api/s/<site>/rest/device/<_id>` with the full `outlet_overrides` array, only the target `relay_state` changed. Refused if the target index is missing from `outlet_overrides`.
- `C4:urlPut` exists with the same signature as `C4:urlPost` plus the 6th options argument (confirmed from the Snap One drivers-common-public `url.lua`).
- TLS: the UniFi console uses a self-signed certificate that Control4 cannot verify against a CA. Certificate verification is therefore turned off for the controller's calls (login, poll, outlet PUT) by passing `TLS_OPTIONS = { ssl_verifypeer = 0, ssl_verifyhost = 0 }` as the 6th argument. Only this controller's HTTPS calls use it. The key names are curl-style and unverified on OS 3.4. If calls still fail with a certificate error, check those key names first.
- Relay proxy: CLOSE = ON, OPEN = OFF, notifications CLOSED = ON and OPENED = OFF.

## Re-login

On HTTP 401 or 403 the driver logs in once and retries the request.

## Password field is not masked

The controller driver's Password property is a plain STRING. Composer in this environment crashes on `<type>PASSWORD</type>` (the Moen drivers carry the same finding), so the value shows in clear text in Composer. Use a dedicated local UniFi admin account with a password used nowhere else.
