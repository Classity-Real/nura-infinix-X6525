#!/usr/bin/env python3
"""Convert the stock wifi_board_config.ini into sprd/wifi_board_config.bin for the
mainline sc23xx driver (sc23xx_load_config).

Everything here is taken from the stock sprd_wlan_combo.ko (the SIPC path,
sprdwl_download_ini): its g_config_table (key -> offset in a flat config struct,
value width in bytes), and the four config messages it sends:

  1: struct bytes [0, 356)                (version .. band-edge offsets)
  2: struct bytes [356, 1828)             (tx scale, misc, debug reg, coex)
  3: struct bytes [1832, 1832+rf_len)     (rf_config TLV; rf_len = number of values)
  4: struct bytes [3332, 3335)            (roaming trigger/delta/5G prefer; not in the ini)

each followed by a CRC-16 (poly 0xA001, init 0xFFFF, no final xor - the stock
CRC_table is the nibble table of CRC-16/MODBUS), little endian. The mainline
loader reads records of  u16le 0x4353 | u16le size | payload  and sends payload
behind a u32 section index (the stock message has a one-byte index and three
pad bytes), so each record's payload is  data + crc16.

usage: wifi-ini2bin.py in.ini out.bin
"""
import re, struct, sys

# key: (offset in the flat struct, bytes per value) - from g_config_table
TABLE = {
    'Major': (0, 2),
    'Minor': (2, 2),
    'Calibration_Bypass': (4, 2),
    '2G_Chain_Mask': (6, 1),
    '5G_Chain_Mask': (7, 1),
    'DPD_LUT_idx': (8, 1),
    'TPC_Goal_Chain0': (16, 2),
    'TPC_Goal_Chain1': (32, 2),
    '2G_LUT_0': (48, 1),
    '2G_LUT_1': (52, 1),
    '2G_LUT_2': (56, 1),
    '2G_LUT_3': (60, 1),
    '2G_LUT_4': (64, 1),
    '2G_LUT_5': (68, 1),
    '2G_LUT_6': (72, 1),
    '2G_LUT_7': (76, 1),
    '5G_LUT_0': (80, 1),
    '5G_LUT_1': (84, 1),
    '5G_LUT_2': (88, 1),
    '5G_LUT_3': (92, 1),
    '5G_LUT_4': (96, 1),
    '5G_LUT_5': (100, 1),
    '5G_LUT_6': (104, 1),
    '5G_LUT_7': (108, 1),
    '2G_Channel_Chain0': (112, 1),
    '2G_Channel_Chain1': (126, 1),
    '5G_Channel_Chain0': (140, 1),
    '5G_Channel_Chain1': (165, 1),
    '11b_Power': (192, 1),
    '11g_Power': (196, 1),
    '11a_Power': (204, 1),
    '11n_2G_Power': (212, 1),
    '11n_5G_Power': (229, 1),
    '11ac_Power': (246, 1),
    'Green_WIFI_offset': (269, 1),
    'HT40_2G_Power_offset': (270, 1),
    'HT40_5G_Power_offset': (271, 1),
    'VHT40_Power_offset': (272, 1),
    'VHT80_Power_offset': (273, 1),
    'SAR_Power_offset': (274, 1),
    'Mean_Power_offset': (275, 1),
    'APC_mode': (276, 1),
    'MAGIC_word': (277, 1),
    'reg_domain1': (280, 4),
    'reg_domain2': (284, 4),
    'BW20M': (288, 1),
    'BW40M': (327, 1),
    'BW80M': (348, 1),
    'Chain0_1': (356, 1),
    'Chain1_1': (980, 1),
    'Chain0_2': (372, 1),
    'Chain1_2': (996, 1),
    'Chain0_3': (388, 1),
    'Chain1_3': (1012, 1),
    'Chain0_4': (404, 1),
    'Chain1_4': (1028, 1),
    'Chain0_5': (420, 1),
    'Chain1_5': (1044, 1),
    'Chain0_6': (436, 1),
    'Chain1_6': (1060, 1),
    'Chain0_7': (452, 1),
    'Chain1_7': (1076, 1),
    'Chain0_8': (468, 1),
    'Chain1_8': (1092, 1),
    'Chain0_9': (484, 1),
    'Chain1_9': (1108, 1),
    'Chain0_10': (500, 1),
    'Chain1_10': (1124, 1),
    'Chain0_11': (516, 1),
    'Chain1_11': (1140, 1),
    'Chain0_12': (532, 1),
    'Chain1_12': (1156, 1),
    'Chain0_13': (548, 1),
    'Chain1_13': (1172, 1),
    'Chain0_14': (564, 1),
    'Chain1_14': (1188, 1),
    'Chain0_36': (580, 1),
    'Chain1_36': (1204, 1),
    'Chain0_40': (596, 1),
    'Chain1_40': (1220, 1),
    'Chain0_44': (612, 1),
    'Chain1_44': (1236, 1),
    'Chain0_48': (628, 1),
    'Chain1_48': (1252, 1),
    'Chain0_52': (644, 1),
    'Chain1_52': (1268, 1),
    'Chain0_56': (660, 1),
    'Chain1_56': (1284, 1),
    'Chain0_60': (676, 1),
    'Chain1_60': (1300, 1),
    'Chain0_64': (692, 1),
    'Chain1_64': (1316, 1),
    'Chain0_100': (708, 1),
    'Chain1_100': (1332, 1),
    'Chain0_104': (724, 1),
    'Chain1_104': (1348, 1),
    'Chain0_108': (740, 1),
    'Chain1_108': (1364, 1),
    'Chain0_112': (756, 1),
    'Chain1_112': (1380, 1),
    'Chain0_116': (772, 1),
    'Chain1_116': (1396, 1),
    'Chain0_120': (788, 1),
    'Chain1_120': (1412, 1),
    'Chain0_124': (804, 1),
    'Chain1_124': (1428, 1),
    'Chain0_128': (820, 1),
    'Chain1_128': (1444, 1),
    'Chain0_132': (836, 1),
    'Chain1_132': (1460, 1),
    'Chain0_136': (852, 1),
    'Chain1_136': (1476, 1),
    'Chain0_140': (868, 1),
    'Chain1_140': (1492, 1),
    'Chain0_144': (884, 1),
    'Chain1_144': (1508, 1),
    'Chain0_149': (900, 1),
    'Chain1_149': (1524, 1),
    'Chain0_153': (916, 1),
    'Chain1_153': (1540, 1),
    'Chain0_157': (932, 1),
    'Chain1_157': (1556, 1),
    'Chain0_161': (948, 1),
    'Chain1_161': (1572, 1),
    'Chain0_165': (964, 1),
    'Chain1_165': (1588, 1),
    'DFS_switch': (1604, 1),
    'power_save_switch': (1605, 1),
    'rssi_report_diff': (1606, 1),
    'Ex_FEM_En': (1607, 1),
    'TX_En_Ctrl': (1608, 1),
    'LNA_En_Ctrl': (1609, 1),
    'SW_En_Ctrl': (1610, 1),
    'LNA_Gain': (1611, 1),
    'LNA_Bypass_Gain': (1612, 1),
    'Ex_FEM_PDET': (1613, 1),
    'address': (1616, 4),
    'value': (1680, 4),
    'bt_performance_cfg0': (1744, 4),
    'bt_performance_cfg1': (1748, 4),
    'wifi_performance_cfg0': (1752, 4),
    'wifi_performance_cfg2': (1756, 4),
    'strategy_cfg0': (1760, 4),
    'strategy_cfg1': (1764, 4),
    'strategy_cfg2': (1768, 4),
    'compatibility_cfg0': (1772, 4),
    'compatibility_cfg1': (1776, 4),
    'ant_cfg0': (1780, 4),
    'ant_cfg1': (1784, 4),
    'isolation_cfg0': (1788, 4),
    'isolation_cfg1': (1792, 4),
    'reserved_cfg0': (1796, 4),
    'reserved_cfg1': (1800, 4),
    'reserved_cfg2': (1804, 4),
    'reserved_cfg3': (1808, 4),
    'reserved_cfg4': (1812, 4),
    'reserved_cfg5': (1816, 4),
    'reserved_cfg6': (1820, 4),
    'reserved_cfg7': (1824, 4),
    'rf_config': (1832, 1),
    'roaming_trigger': (3332, 1),
    'roaming_delta': (3333, 1),
    'roaming_5g_prefer': (3334, 1)
}

RF_LEN_OFF, RF_DATA_OFF, ROAM_OFF = 1828, 1832, 3332
SIZE = 3336

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc

def parse(path):
    """-> (flat struct bytes, rf value count, unknown keys)"""
    buf = bytearray(SIZE)
    rf_len, unknown = 0, []
    for line in open(path, errors="replace"):
        line = line.split("#")[0].strip()
        if not line or line.startswith("["):
            continue
        m = re.match(r"([\w-]+)\s*=\s*(.*)$", line)
        if not m:
            continue
        key = m.group(1)
        vals = [int(v, 0) for v in re.split(r"[,\s]+", m.group(2).strip()) if v]
        if key not in TABLE:
            unknown.append(key)
            continue
        off, width = TABLE[key]
        for i, v in enumerate(vals):
            v &= (1 << (8 * width)) - 1
            struct.pack_into("<" + {1: "B", 2: "H", 4: "I"}[width], buf, off + i * width, v)
        if key == "rf_config":
            rf_len = len(vals)
    struct.pack_into("<I", buf, RF_LEN_OFF, rf_len)
    return bytes(buf), rf_len, unknown

def sections(buf, rf_len):
    return [buf[0:356], buf[356:1828], buf[RF_DATA_OFF:RF_DATA_OFF + rf_len], buf[ROAM_OFF:ROAM_OFF + 3]]

def build(buf, rf_len):
    out = bytearray()
    for data in sections(buf, rf_len):
        payload = data + struct.pack("<H", crc16(data))
        out += struct.pack("<HH", 0x4353, len(payload)) + payload
    return bytes(out)

def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    buf, rf_len, unknown = parse(sys.argv[1])
    if unknown:
        print("warning: keys not in the stock table, ignored:", ", ".join(unknown), file=sys.stderr)
    data = build(buf, rf_len)
    open(sys.argv[2], "wb").write(data)
    print(f"4 sections ({[len(s) for s in sections(buf, rf_len)]} bytes + crc), {len(data)} bytes -> {sys.argv[2]}")

if __name__ == "__main__":
    main()
