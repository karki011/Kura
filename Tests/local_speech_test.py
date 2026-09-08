import importlib.util
import pathlib
import unittest

source = pathlib.Path(__file__).resolve().parents[1] / "Sources/Kura/Resources/local_speech.py"
spec = importlib.util.spec_from_file_location("local_speech", source)
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class LocalSpeechTests(unittest.TestCase):
    def test_overlap_preserves_speaker_identity(self):
        previous = [(0, 8, 0), (8, 15, 1)]
        turns, next_id = worker.match_speakers([(5, 8, "B"), (8, 18, "A")], previous, 2)
        self.assertEqual(turns, [(5, 8, 0), (8, 18, 1)])
        self.assertEqual(next_id, 2)

    def test_new_speaker_does_not_reuse_stale_identity(self):
        turns, next_id = worker.match_speakers([(40, 45, "A")], [(0, 8, 0)], 1)
        self.assertEqual(turns[0][2], 1)
        self.assertEqual(next_id, 2)

    def test_words_align_and_old_overlap_is_not_repeated(self):
        words = [{"text": "Old", "offsets": {"from": 0, "to": 1000}},
                 {"text": " What", "offsets": {"from": 10000, "to": 10500}},
                 {"text": " next?", "offsets": {"from": 10500, "to": 11000}}]
        result = worker.align_words([{"tokens": words}], [(0, 9, 0), (9, 12, 1)], 0, 10)
        self.assertEqual(result, [{"speaker": 1, "text": "What next?", "start": 10.0}])

    def test_unknown_voice_is_not_assigned_a_name(self):
        result = worker.align_words([{"text": "Hi", "offsets": {"from": 0, "to": 1000}}], [], 0, 0)
        self.assertEqual(result[0]["speaker"], -1)


if __name__ == "__main__":
    unittest.main()
