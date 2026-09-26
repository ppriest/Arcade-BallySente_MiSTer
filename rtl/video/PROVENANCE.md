# rtl/video provenance

Everything here is this core's own except:

| File | Origin | Licence | Changes |
|---|---|---|---|
| `screen_rotate_two.sv` | Sorgelig, "Screen +90/-90 deg. rotation", copied from the Arcade-Fuuki_MiSTer core, which took it from Arcade-SKNS_MiSTer | GPL-2.0-or-later | none |

`screen_rotate_two` is used for HDMI orientation only; its `flip` input is tied off because flip
screen is done in `video.sv`, so HDMI and analog show the same picture.
