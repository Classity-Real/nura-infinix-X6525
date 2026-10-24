#!/usr/bin/env python3
"""Convert the stock bt_configure_{pskey,rf}.ini into the blobs btsprdsipc sends.

The mainline btsprdsipc driver does not parse the stock INI files: probe()
request_firmware()s two flat binaries, sprd/bt_config_pskey.bin and
sprd/bt_config_rf.bin, and sends them as the payloads of HCI commands 0xfca0
(pskey) and 0xfca2 (RF), followed by 0xfca1 (enable) and a reset. If either
file is missing, probe() returns an error and there is no HCI device at all.

The layout is the stock "Marlin3" configuration struct: every entry of the
used INI sections in file order, each value little-endian and truncated to
the width the struct declares. Two independent checks that this is right:

  - the sizes are fixed: 160 bytes for pskey and 252 bytes for RF, which is
    what the stock INI headers announce ("Total Length=160"/"=252");
  - device_addr lands at offset 20 in the pskey blob (device_class is 4 bytes
    and feature_set 16), and btsprdsipc_set_bdaddr() overwrites exactly
    six bytes at pskey_cfg + 20 with the adapter's address.

The field tables are the hardware's format, cross-checked against the
marlin3 tables in device-bsp-s19mps (Jolla C2, same UMS9230 WCN block),
convert_ini.py, which generates the same two files for that phone.

The INIs come off the stock ROM: /odm/firmware/bt_configure_pskey.ini and
/odm/firmware/bt_configure_rf.ini.

usage: bt-ini2bin.py pskey in.ini out.bin
       bt-ini2bin.py rf     in.ini out.bin
"""
import sys

# (name, number of values, bytes per value); None is padding.
PSKEY = [
    ('device_class', 1, 4),
    ('feature_set', 16, 1),
    ('device_addr', 6, 1),
    ('comp_id', 1, 2),
    ('g_sys_uart0_communication_supported', 1, 1),
    ('cp2_log_mode', 1, 1),
    ('LogLevel', 1, 1),
    ('g_central_or_perpheral', 1, 1),
    ('Log_BitMask', 1, 2),
    ('super_ssp_enable', 1, 1),
    ('common_rfu_b3', 1, 1),
    ('common_rfu_w', 2, 4),
    ('le_rfu_w', 2, 4),
    ('lmp_rfu_w', 2, 4),
    ('lc_rfu_w', 2, 4),
    ('g_wbs_nv_117', 1, 2),
    ('g_wbs_nv_118', 1, 2),
    ('g_nbv_nv_117', 1, 2),
    ('g_nbv_nv_118', 1, 2),
    ('g_sys_sco_transmit_mode', 1, 1),
    ('audio_rfu_b1', 1, 1),
    ('audio_rfu_b2', 1, 1),
    ('audio_rfu_b3', 1, 1),
    ('audio_rfu_w', 2, 4),
    ('g_sys_sleep_in_standby_supported', 1, 1),
    ('g_sys_sleep_master_supported', 1, 1),
    ('g_sys_sleep_slave_supported', 1, 1),
    ('power_rfu_b1', 1, 1),
    ('power_rfu_w', 2, 4),
    ('win_ext', 1, 4),
    ('edr_tx_edr_delay', 1, 1),
    ('edr_rx_edr_delay', 1, 1),
    ('tx_delay', 1, 1),
    ('rx_delay', 1, 1),
    ('bb_rfu_w', 2, 4),
    ('agc_mode', 1, 1),
    ('diff_or_eq', 1, 1),
    ('ramp_mode', 1, 1),
    ('modem_rfu_b1', 1, 1),
    ('modem_rfu_w', 2, 4),
    ('BQB_BitMask_1', 1, 4),
    ('BQB_BitMask_2', 1, 4),
    ('bt_coex_threshold', 8, 2),
    ('other_rfu_w', 2, 4),
]

RF = [
    ('g_GainValue_A', 6, 2),
    ('g_ClassicPowerValue_A', 10, 2),
    ('g_LEPowerValue_A', 16, 2),
    ('g_BRChannelpwrvalue_A', 8, 2),
    ('g_EDRChannelpwrvalue_A', 8, 2),
    ('g_LEChannelpwrvalue_A', 8, 2),
    ('g_GainValue_B', 6, 2),
    ('g_ClassicPowerValue_B', 10, 2),
    ('g_LEPowerValue_B', 16, 2),
    ('g_BRChannelpwrvalue_B', 8, 2),
    ('g_EDRChannelpwrvalue_B', 8, 2),
    ('g_LEChannelpwrvalue_B', 8, 2),
    ('LE_fix_powerword', 1, 2),
    ('Classic_pc_by_channel', 1, 1),
    ('LE_pc_by_channel', 1, 1),
    ('RF_switch_mode', 1, 1),
    ('Data_Capture_Mode', 1, 1),
    ('Analog_IQ_Debug_Mode', 1, 1),
    ('RF_common_rfu_b3', 1, 1),
    ('RF_common_rfu_w', 5, 4),
]

MODES = {
    'pskey': (PSKEY, 160),
    'rf': (RF, 252),
}


def parse_ini(path):
    """key -> list of ints, for every `key = 0x.., 0x..` entry in the file."""
    config = {}
    buf = ''
    with open(path) as f:
        for line in f:
            if line.isspace() or line.startswith('#') or line.startswith('['):
                continue
            buf += line.strip()
            if buf.endswith(','):      # values continue on the next line
                continue
            if '=' not in buf:
                raise SystemExit(f'{path}: cannot parse: {buf!r}')
            key, val = buf.split('=', 1)
            config[key.strip()] = [int(x.strip(), 0) for x in val.split(',')]
            buf = ''
    if buf:
        raise SystemExit(f'{path}: truncated last entry: {buf!r}')
    return config


def build(fields, config, path):
    out = bytearray()
    for name, count, size in fields:
        if name is None:
            val = [0] * count
        elif name in config:
            val = config[name]
        else:
            raise SystemExit(f'{path}: missing entry {name}')
        if len(val) != count:
            raise SystemExit(f'{path}: {name} has {len(val)} values, '
                             f'the struct takes {count}')
        for item in val:
            out += (item & ((1 << (size * 8)) - 1)).to_bytes(size, 'little')
    return bytes(out)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in MODES:
        sys.exit(__doc__.strip().splitlines()[-1])
    mode, src, dst = sys.argv[1:]
    fields, want = MODES[mode]
    blob = build(fields, parse_ini(src), src)
    if len(blob) != want:
        sys.exit(f'{src}: built {len(blob)} bytes, the struct is {want}')
    if mode == 'pskey':
        # btsprdsipc_set_bdaddr() patches the adapter address in at this offset
        dev = blob[20:26]
        if dev == bytes(6):
            sys.exit(f'{src}: device_addr at offset 20 is all zero')
    with open(dst, 'wb') as f:
        f.write(blob)
    print(f'{src} -> {dst}: {len(blob)} bytes')


if __name__ == '__main__':
    main()
