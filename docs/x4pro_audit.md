# X4 Pro Lua App Control Audit

**106 apps analyzed**

## Device context

| Physical button | Fires Lua event |
|---|---|
| Left (GPIO0) | `"up"` |
| Right (GPIO7) | `"down"` |
| Power (short) | `"confirm"` (if PWR_CONFIRM enabled) |
| Touch tap (main area) | `"confirm"` + `input.pos()` coords |
| Touch swipe L→R | `"back"` |
| **Left/Right events** | **No physical source** |
| **Confirm hold/Back hold** | **No physical source** |

---

## Needs fix

| App | Category | Events used | Issues |
|---|---|---|---|
| checkers_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| chess_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| connectfour_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| dungeon_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| game2048_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| go_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| guesswho_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| hearts_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| hex_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| jaipur_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| knucklebones_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| minesweeper_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| murdle_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| picross_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| play_nearby_ttt_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| seasalt_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| sudoku_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| underhand_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| wavelength_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| wordle_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| yahtzee_lua | games | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| player_lua | media | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| airtag_test_lua | network | up, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| ble_beacon_lua | network | up, down, left, right, confirm, back, up_hold, down_hold | up/down_hold: works physically but check if confirm_hold also needed; left+right: no physical mapping (remap needed) |
| gatt_browser_lua | network | up, down, right, confirm, back | right: no physical mapping |
| ha_frontend_lua | network | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| cover_grid_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| hackernews_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| koreader_sync_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| library_grid_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| notes_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| opds_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| study_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| trivia_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| txt_reader_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| xkcd_lua | reading | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| medical_id_lua | security | up, down, right, confirm, back | right: no physical mapping |
| quick_wipe_lua | security | up, down, left, confirm, back | left: no physical mapping |
| screen_decoy_lua | security | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| totp_lua | security | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| calculator_lua | tools | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| counter_lua | tools | up, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| ap_picker_lua | wifi | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| capture_sessions_lua | wifi | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| heat_map_lua | wifi | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |
| ruby_capture_browser_lua | wifi | up, down, left, right, confirm, back | left+right: no physical mapping (remap needed) |

## Works (confirm+back via touch)

| App | Category | Events used |
|---|---|---|
| forehead_lua | games | up, down, confirm, back |
| grimoire_lua | games | up, down, confirm, back |
| ble_remote_lua | network | up, down, confirm, back |
| ble_scanner_lua | network | back |
| ble_sensor_lua | network | up, down, confirm, back |
| ble_spam_lua | network | up, down, confirm, back |
| bulletin_board_lua | network | confirm, back |
| captive_portal_lua | network | back |
| dead_drop_lua | network | back |
| dns_lookup_lua | network | confirm, back |
| emergency_sos_lua | network | up, down, back |
| host_scanner_lua | network | up, down, confirm, back |
| http_client_lua | network | up, down, confirm, back |
| mdns_browser_lua | network | up, down, confirm, back |
| mesh_chat_lua | network | confirm, back |
| port_knocker_lua | network | back |
| softap_files_lua | network | back |
| ssid_channel_lua | network | back |
| tcp_ping_lua | network | back |
| udp_discovery_lua | network | up, down, confirm, back |
| ao3_lua | reading | back |
| file_browser_lua | reading | up, down, confirm, back |
| stardict_lua | reading | confirm, back |
| credential_viewer_lua | security | up, down, back |
| password_manager_lua | security | up, down, confirm, back |
| pin_lock_lua | security | back |
| qr_family_lua | security | up, down, confirm, back |
| rf_kill_lua | security | confirm, back |
| sd_encrypt_lua | security | back |
| stego_bmp_lua | security | back |
| vendor_oui_lua | security | confirm, back |
| demo_lua | system | back |
| grants_lua | system | back |
| lua_tests_lua | system | up, down, confirm, back |
| app_store_lua | tools |  |
| archive_browser_lua | tools | up, down, confirm, back |
| clock_lua | tools | back |
| diagnostics_lua | tools | confirm, back |
| event_logger_lua | tools | back |
| network_mode_lua | tools | confirm, back |
| ntp_clock_lua | tools | confirm, back |
| timers_lua | tools | up, down, confirm, back |
| ap_cloner_lua | wifi | up, down, confirm, back |
| ap_history_lua | wifi | back |
| beacon_flood_lua | wifi | back |
| beacon_test_lua | wifi | back |
| breadcrumb_lua | wifi | back |
| crowd_density_lua | wifi | back |
| deauth_detector_lua | wifi | back |
| deauth_test_lua | wifi | up, down, confirm, back |
| eapol_hunt_lua | wifi | up, down, confirm, back |
| fire_lua | wifi | back |
| network_change_lua | wifi | confirm, back |
| passive_sniffer_lua | wifi | up, down, confirm, back |
| perimeter_watch_lua | wifi | back |
| probe_sniffer_lua | wifi | up, down, confirm, back |
| signal_locator_lua | wifi | up, down, confirm, back |
| transit_alert_lua | wifi | up, down, confirm, back |
| vehicle_finder_lua | wifi | up, down, confirm, back |
| wifi_spectrum_lua | wifi | confirm, back |

## No user interaction (background/display-only)

| App | Category |
|---|---|
