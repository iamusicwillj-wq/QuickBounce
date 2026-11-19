import importlib.util
import struct
import tempfile
import unittest
import wave
from pathlib import Path

import numpy as np

spec = importlib.util.spec_from_file_location('alignment', Path(__file__).with_name('inspect_bounce_alignment.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def wav(path, data, rate=48000):
    with wave.open(str(path), 'wb') as f:
        f.setnchannels(data.shape[1]); f.setsampwidth(2); f.setframerate(rate)
        f.writeframes((np.clip(data, -.99, .99) * 32767).astype('<i2').tobytes())


class AlignmentTests(unittest.TestCase):
    def test_pcm24_float_and_extensible_decode_and_bwf_is_not_alignment(self):
        with tempfile.TemporaryDirectory() as folder:
            values = np.array([[-.5, .25], [0., .75]], dtype=np.float64)
            for code, bits, extensible in [(1, 24, False), (3, 32, False), (3, 64, True), (1, 16, True)]:
                p = Path(folder) / f'{code}-{bits}-{extensible}.wav'
                if code == 3:
                    raw = values.astype('<f4' if bits == 32 else '<f8').tobytes()
                elif bits == 24:
                    integers = (values.flatten() * 8388608).astype(np.int32)
                    raw = b''.join((int(x) & 0xffffff).to_bytes(3, 'little') for x in integers)
                else:
                    raw = (values * 32768).astype('<i2').tobytes()
                fmt = struct.pack('<HHIIHH', 0xfffe if extensible else code, 2, 48000,
                                  48000 * 2 * bits // 8, 2 * bits // 8, bits)
                if extensible:
                    fmt += struct.pack('<HHI', 22, bits, 3) + struct.pack('<I', code) + bytes.fromhex('00001000800000aa00389b71')
                bext = bytearray(602)
                struct.pack_into('<Q', bext, 338, 9007199254740993)
                body = b'WAVE' + b'fmt ' + struct.pack('<I', len(fmt)) + fmt
                body += b'bext' + struct.pack('<I', len(bext)) + bext
                body += b'data' + struct.pack('<I', len(raw)) + raw
                p.write_bytes(b'RIFF' + struct.pack('<I', len(body)) + body)
                decoded = module.Wave(p)
                np.testing.assert_allclose(decoded.read(0, 2), values, atol=1e-7)
                self.assertEqual(decoded.bwf_time_reference, 9007199254740993)

    def test_three_matching_windows_are_required_and_negative_offset_is_supported(self):
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / 'a.wav', Path(folder) / 'b.wav'
            signal = np.random.default_rng(22).normal(0, .1, (144000, 1))
            wav(a, signal); wav(b, signal[1602:])
            result = module.compare(a, b, selection_start=48000)
            self.assertEqual(result['offset_in_padded_samples'], -1602)
            self.assertEqual(result['proposed_placement_samples'], 49602)
            wav(a, signal[:10000]); wav(b, signal[:10000])
            self.assertEqual(module.compare(a, b)['status'], 'inconclusive')

    def test_known_offset_gain_and_stereo(self):
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / 'a.wav', Path(folder) / 'b.wav'
            signal = np.random.default_rng(8).normal(0, .1, (144000, 2))
            wav(a, signal)
            wav(b, np.concatenate((np.zeros((1919, 2)), signal * .7, np.zeros((1920, 2)))))
            result = module.compare(a, b, selection_start=48000)
            self.assertEqual(result['status'], 'observed_consistent_offset')
            self.assertEqual(result['offset_in_padded_samples'], 1919)
            self.assertEqual(result['proposed_placement_samples'], 46081)

    def test_silence_and_periodic_tone_are_not_alignment_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / 'a.wav', Path(folder) / 'b.wav'
            for signal in [np.zeros((144000, 1)), np.sin(np.arange(144000) * 2 * np.pi / 48).reshape(-1, 1) * .2]:
                wav(a, signal); wav(b, signal)
                self.assertEqual(module.compare(a, b)['status'], 'inconclusive')

    def test_different_signal_and_rate_mismatch(self):
        with tempfile.TemporaryDirectory() as folder:
            a, b = Path(folder) / 'a.wav', Path(folder) / 'b.wav'
            rng = np.random.default_rng(9)
            wav(a, rng.normal(0, .1, (144000, 1)))
            wav(b, rng.normal(0, .1, (144000, 1)))
            self.assertEqual(module.compare(a, b)['status'], 'inconclusive')
            wav(b, np.zeros((144000, 1)), rate=44100)
            with self.assertRaisesRegex(ValueError, 'identical sample rates'):
                module.compare(a, b)

    def test_malformed_and_unsupported_waves(self):
        with tempfile.TemporaryDirectory() as folder:
            p = Path(folder) / 'bad.wav'
            p.write_bytes(b'RF64' + b'\0' * 4 + b'WAVE')
            with self.assertRaises(ValueError): module.Wave(p)
            p.write_bytes(b'RIFF' + struct.pack('<I', 200) + b'WAVE')
            with self.assertRaisesRegex(ValueError, 'Truncated'): module.Wave(p)


if __name__ == '__main__':
    unittest.main()
