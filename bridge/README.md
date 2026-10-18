# netsim bridge

The emulator side of MacPhone's Bluetooth bridge. MacPhone starts it itself when you press **Mirror to Emulator**; this folder is for working on it.

`macphone_netsim_bridge.py` connects to MacPhone on `127.0.0.1:8765`, receives the GATT table of the device MacPhone is connected to, and publishes the same services, name and manufacturer data as a [Bumble](https://github.com/google/bumble) peripheral on netsim, the Android emulator's virtual Bluetooth controller.

## Protocol

One JSON object per line. The client must open with `{"cmd":"hello","token":"…"}`. MacPhone passes the token in `MACPHONE_BRIDGE_TOKEN` and also writes it to `~/Library/Application Support/MacPhone/bridge-token` (mode 0600) for a bridge started by hand. Any other first line closes the connection.

| From MacPhone | Meaning |
|---|---|
| `{"type":"state","value":"connected"}` | The real device is connected or gone (`disconnected`). |
| `{"type":"gatt","services":[…],"advertisement":{…}}` | The full GATT table, sent once discovery is complete and again after every reconnect. |
| `{"type":"readResult","service":"…","characteristic":"…","value":"<hex>"}` | Answer to a read. |
| `{"type":"notification",…}` | A notification or indication from the device. |

| To MacPhone | Meaning |
|---|---|
| `{"cmd":"read","service":"…","characteristic":"…"}` | Read a value. |
| `{"cmd":"write",…,"value":"<hex>","withResponse":true}` | Write a value. |
| `{"cmd":"subscribe",…,"enabled":true}` | Turn notifications on or off. |
| `{"cmd":"resetSession"}` | The emulator client left; reconnect the real device for a clean session. |

UUIDs and hex payloads are validated in MacPhone before anything reaches CoreBluetooth.

The bridge exits with code 75 when MacPhone switches to a device with a different GATT layout. MacPhone restarts it, because Bumble cannot swap services while advertising.

## Running it by hand

```bash
cd bridge
./run_bridge.sh          # creates .venv from requirements.txt on first run
```

Needs a running Android emulator and a device or the demo device active in MacPhone.

## Testing without MacPhone or hardware

```bash
./run_demo.sh
```

Starts `mock_bridge_server.py` (a fake battery and UART device), the bridge, and `netsim_central_probe.py`, which connects from the emulator side, reads and subscribes. Needs only a running Android emulator.

## Settings

| Variable | Default | |
|---|---|---|
| `MACPHONE_BRIDGE_PORT` | `8765` | MacPhone's socket. |
| `MACPHONE_NETSIM_TRANSPORT` | found from `netsim.ini` | Bumble transport, for example `android-netsim:127.0.0.1:8554`. |
| `MACPHONE_CLIENT_IDLE_TIMEOUT` | `120` | Seconds without reads, writes or notifications before an emulator client is disconnected. |
