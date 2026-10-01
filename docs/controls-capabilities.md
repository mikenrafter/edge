# Controls capability evidence

Reviewed baseline: `05ca7a7`, Flutter 3.41.6, algorithm 97, schema 54,
app 0.10.0+67. This is a source inventory; hardware execution requires the
real-band checks in the roadmap.

| Capability | WHOOP 4 | WHOOP 5 / MG | Evidence and limits |
|---|---|---|---|
| Native RTC alarm | Supported arm path | Supported slot-1 arm path | `BleEngine.setAlarm`, `AlarmPayloads`; unconfirmed writes are not proof of firing |
| Alarm confirmation | History events | History events | `AlarmConfirmation`; confirmation can arrive on the next sync |
| Live haptic | Pattern selection | Fixed verified waveform | `BleEngine.buzzPattern`; arbitrary Android waveform matching is unavailable |
| Firmware double tap | Event path | Capability-dependent event path | `AppState` band event handler; no evidence for single/triple/quadruple tap classification |
| High-rate IMU | Live stream path | Generation-specific live stream path | `BleEngine` live ownership reconciler; RAM only |
| Worn state | Sensor/event evidence | Sensor/event evidence | Unknown evidence must remain unknown; connection alone does not prove wear |
| Background wake | Native armed fallback | Native armed fallback | Phone-driven early haptics require a running phone and link; iOS needs a macOS and real-device check |

Other adapters expose their own supported signals through
`lib/ble/adapters/_registry.dart`. A WHOOP capability does not imply support on
another adapter.

Run `python3 scripts/opcode_inventory.py` to produce source locations for the
destructive-write guards and command call sites. The inventory records source
references, not hardware validation. `test/ble_safe_trim_test.dart`,
`test/ack_commit_sync_full_test.dart`, `test/adapters/gatt_link_write_test.dart`,
and `test/gen5_wiring_test.dart` provide regression coverage for those paths.
