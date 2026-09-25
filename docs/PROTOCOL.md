# X6 BLE protocol observations

Observed on an **Insta360 X6, firmware v1.1.7**, 2026-09-13. These findings apply
to this camera/firmware; they are not a vendor compatibility guarantee.

## GATT

The camera advertises a name such as `X6 XXXXXX`. A Windows test connection negotiated ATT MTU 517.
Bluetooth base UUID: `0000xxxx-0000-1000-8000-00805f9b34fb`.

| UUID | Properties | Observed use |
|---|---|---|
| BE80 | service | Direct control |
| BE81 | read, write | Commands, ATT write with response |
| BE82 | notify | Responses and unsolicited events |
| BE83 | read | Unused |
| BE84 / BE86 | read, write | Unused |
| BE85 / BE87 | notify | Unused |

Standard services 1800 and 1801 also appeared. No standard firmware characteristic
was present; firmware/model were read using GET_OPTIONS for fields 30 and 48 only.

## UCD2

The camera immediately sent UCD2 notifications. The old Header16 candidate got no
correlated status response. UCD2 status, START and STOP subsequently worked.

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 4 | ASCII `UCD2` |
| 4 | 1 | Version 1 |
| 5 | 1 | Header size 12 |
| 6 | 1 | 4: command/event; 5: observed heartbeat |
| 7 | 1 | Transport sequence |
| 8 | 4 | Little-endian payload length, excluding outer header and checksum |
| 12 | 2 | Little-endian command or response code |
| 14 | 1 | Content type 2 (protobuf) |
| 15 | 4 | Message ID and flags: low 30 bits ID, bit 31 final fragment |
| 19 | 2 | Reserved |
| 21 | variable | Protobuf body |
| end-4 | 4 | Little-endian camera CRC |

CRC uses polynomial `0x04c11db7`, initial value `0xffffffff`, with each byte XORed
into the low byte followed by 32 MSB-first rounds. This is not `zlib.crc32`.
Parser checks length, content type, final-fragment flag and CRC before accepting
a response, and supports notification chunks split at arbitrary byte boundaries.
Encrypted headers and logical multi-fragment messages are currently unsupported.

Replies use code 200 for success and echo the request's full message ID. A successful
ATT write alone is not a camera acknowledgement. An acknowledgement alone is not
recording-state confirmation. Unsolicited events do not satisfy pending requests.

## Narrow command set

| Code | Request body | Purpose / verified response |
|---|---|---|
| 4 | empty | Explicit normal-video START |
| 5 | empty | Explicit STOP; response included saved `.insv` filename |
| 15 | empty | GET_CURRENT_CAPTURE_STATUS |
| 8 | `08 1e 08 30` | Firmware/model only |

No generic shutter toggle is implemented. No arbitrary command write interface,
mode changes, card formatting, deleting files, Wi-Fi setup or preview is exposed.

Status response has field 1 containing a nested status message. Nested field 1
was 0 when idle and 1 during normal recording; field 2 advanced as elapsed seconds.
Field 10 appeared with value 0 and remains uninterpreted. Missing or other state
values return UNKNOWN, never an assumed STOPPED value.

Actual capture-status response bodies:

```text
Idle:       0a06080010005000
Recording:  0a06080110085000   (8 seconds)
```

Observed event codes include 8195 (battery data), 8208 (capture status), 8215, and
20601 in type-5 heartbeat frames. We do not echo those unsolicited frames or infer
capture success from them. The window polls status once per idle event-loop second.

## Sources and provenance

### September 15 experimental battery / storage reads

Watch candidate 0.1.3 (4) adds read-only GET_OPTIONS code 8, body `08 0b 08 14`:
option_types BATTERY_STATUS=11 and STORAGE_STATE=20. It does not request all
options or write any configuration. Existing START/STOP/status bytes are unchanged.

Schema reference pinned to RigacciOrg/insta360-wifi-api commit
`89320e06a2395140e9e506a735c59a7ff8d88446` (field facts only; no generated code copied):

- `pb2/get_options_pb2.py`: response field 2 is Options.
- `pb2/options_pb2.py`: Options field 11 is BatteryStatus, 20 is StorageState;
  OptionType numbers match 11 and 20.
- `pb2/battery_pb2.py`: fields 2=level, 3=scale, 4=battery type (100=no battery).
- `pb2/battery_update_pb2.py`: event body field 1 wraps BatteryStatus.
- `pb2/storage_pb2.py`: fields 1=card state, 2=free space, 3=total space,
  4=location (0=camera). State 0=pass, 1=no card, 2=no space, 3..5=card errors.

The real `live-3` fixture battery event 8195 has body `0a0408001064`: explicit
level 100, omitted scale. For this X6 profile only, an explicit level 0..100 with
omitted scale is treated as percent. A provided scale must be positive; otherwise
the reading is unavailable. Proto3 omitted zero level/free space is accepted only
with supporting explicit scale/capacity, not from an empty nested message.

Battery/storage GET_OPTIONS replies still require live validation, including free
space units (currently interpreted as bytes) and SD-card location. Missing options
are unavailable, never assumed zero. The existing real battery event is replayed
in tests; new options-response edge cases use schema-derived synthetic data and
are not labelled as camera captures. Readout failures do not affect capture state.

The Watch logs bounded `telemetry_reply` body hex (at most 128 bytes) and decoded
battery/free/total/card fields, for comparison with the camera when Detailed logging is on.
No telemetry is added to notification content or background polling.

### Original control references

- [diamondfsd/luna-ai-cut BLE codec](https://github.com/diamondfsd/luna-ai-cut/blob/12475df7a89f5b73eec959aef3b62dfdff9d055f/electron/devices/insta360/lunaBleCodec.ts):
  UCD2 frame/checksum facts and implementation reference, MIT; notice retained.
- [insta360ctl protocol](https://github.com/xaionaro-go/insta360ctl/blob/f94193ce03c5af0921a9992bfd1af6bd946150d0/doc/protocol.md):
  initial service/command leads for earlier models; its Header16 framing did not
  establish X6 control. No source code from that unlicensed repository is vendored.
- [RigacciOrg protobuf descriptors](https://github.com/RigacciOrg/insta360-wifi-api/tree/main/pb2):
  capture-status envelope, command meanings and option-field leads; checked against
  live X6 responses. Generated files were not copied into this application.
- [Insta360 iOS SDK](https://github.com/Insta360Develop/iOS-SDK): official high-level
  capture APIs and session guidance; not used by this app.

These are references only, not runtime dependencies.
