"""Verify the ABI used by the AV audio mix, without an audio device or a real source."""
import ctypes as c
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1] / "MediaKit/Sources/CLiveRemux"
with tempfile.TemporaryDirectory() as work:
    binary = pathlib.Path(work) / "libgain.so"
    subprocess.run(["cc", "-std=c11", "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror",
                    "-I", str(root / "include"), str(root / "AudioGain.c"), "-o", str(binary)], check=True)
    lib = c.CDLL(str(binary))
    for name, kind, source, expected in [
        ("float", c.c_float, [-2, -0.25, 0, 0.25, 0.75, float("nan")], [-1, -0.5, 0, 0.5, 1, 0]),
        ("int16", c.c_int16, [-32768, -12001, 0, 10000, 32767], [-32768, -24002, 0, 20000, 32767]),
        ("int32", c.c_int32, [-2147483648, -1000000000, 0, 900000000, 2147483647],
                              [-2147483648, -2000000000, 0, 1800000000, 2147483647]),
    ]:
        fn = getattr(lib, "pl_gain_" + name)
        fn.argtypes = [c.POINTER(kind), c.c_uint32, c.c_int32]
        fn.restype = None
        data = (kind * (len(source) + 1))(*(source + [31]))
        saved = bytes(data)
        fn(data, len(source), 100)
        assert bytes(data) == saved
        fn(data, len(source), 200)
        assert list(data) == expected + [31]
print("App PCM gain: exact bypass, gain on every channel, clipping, non-finite input and buffer boundaries passed")
