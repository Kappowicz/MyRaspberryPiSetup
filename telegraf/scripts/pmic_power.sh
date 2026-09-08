#!/bin/sh
# Raspberry Pi 5 PMIC power metrics (Watts) -> InfluxDB line protocol
VCGENCMD="/hostfs/usr/bin/vcgencmd"
if [ ! -x "$VCGENCMD" ]; then
    VCGENCMD="vcgencmd"
fi

"$VCGENCMD" pmic_read_adc 2>/dev/null | awk '
{
    for (f=1; f<=NF; f++) {
        if ($f ~ /_A$/) {
            rail = $f; sub(/_A$/, "", rail)
            val = $(f+1); sub(/.*=/, "", val); sub(/A$/, "", val)
            cur[rail] = val + 0
        } else if ($f ~ /_V$/) {
            rail = $f; sub(/_V$/, "", rail)
            val = $(f+1); sub(/.*=/, "", val); sub(/V$/, "", val)
            volt[rail] = val + 0
        }
    }
}
END {
    total_w = 0
    for (r in cur) {
        if (r in volt) {
            p = cur[r] * volt[r]
            total_w += p
        }
    }
    if (total_w == 0) exit 1

    # PMIC efficiency ~85-90%, plus ~0.60W board baseline overhead
    est_total_w = total_w * 1.15 + 0.60

    vdd_core_w = ("VDD_CORE" in cur && "VDD_CORE" in volt) ? cur["VDD_CORE"] * volt["VDD_CORE"] : 0
    sys3v3_w   = ("3V3_SYS" in cur && "3V3_SYS" in volt)     ? cur["3V3_SYS"] * volt["3V3_SYS"] : 0
    sys1v8_w   = ("1V8_SYS" in cur && "1V8_SYS" in volt)     ? cur["1V8_SYS"] * volt["1V8_SYS"] : 0
    sys1v1_w   = ("1V1_SYS" in cur && "1V1_SYS" in volt)     ? cur["1V1_SYS"] * volt["1V1_SYS"] : 0
    sw0v8_w    = ("0V8_SW" in cur && "0V8_SW" in volt)       ? cur["0V8_SW"] * volt["0V8_SW"] : 0
    ddr_w      = ("DDR_VDD2" in cur && "DDR_VDD2" in volt)   ? cur["DDR_VDD2"] * volt["DDR_VDD2"] : 0
    ext5v_v    = ("EXT5V" in volt)                           ? volt["EXT5V"] : 0

    printf "rpi_power,host=malinka power_w=%.4f,est_total_w=%.4f,ext5v_v=%.4f,vdd_core_w=%.4f,sys3v3_w=%.4f,sys1v8_w=%.4f,sys1v1_w=%.4f,sw0v8_w=%.4f,ddr_w=%.4f\n", \
        total_w, est_total_w, ext5v_v, vdd_core_w, sys3v3_w, sys1v8_w, sys1v1_w, sw0v8_w, ddr_w
}'
