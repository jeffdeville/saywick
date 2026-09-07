import unittest
from bench import score, regression_issues

class PauseScoringTests(unittest.TestCase):
    def case(self, reference='Please send the report tomorrow.', before=4, kind='thinking'):
        return dict(reference=reference, pauses=[dict(before_word=before, kind=kind)])

    def test_exact_words_can_still_have_false_sentence_and_capital(self):
        result = score(self.case(), 'Please send the report. Tomorrow.')
        self.assertEqual(result['wer'], 0)
        self.assertEqual(result['false_sentence_breaks'], 1)
        self.assertEqual(result['false_capitals'], 1)

    def test_capitalization_inside_a_resumed_phrase_is_scored(self):
        result = score(self.case('Please pick up the blue notebook.', 3),
                       'Please pick up. The Blue Notebook.')
        self.assertEqual(result['false_capitals'], 1)
        self.assertEqual(result['unexpected_capitals'], 3)
        self.assertEqual(result['wer'], 0)

    def test_real_sentence_must_keep_its_break(self):
        result = score(self.case('The report is ready. Please send it.', 4, 'sentence'),
                       'The report is ready please send it.')
        self.assertEqual(result['missed_sentence_breaks'], 1)
        self.assertEqual(result['false_capitals'], 0)

    def test_proper_noun_is_not_false_capital(self):
        result = score(self.case('Please send the report Monday.', 4), 'Please send the report Monday.')
        self.assertEqual(result['false_capitals'], 0)

    def test_missing_anchor_is_unscorable_and_word_error(self):
        result = score(self.case(), 'Please send tomorrow.')
        self.assertEqual(result['word_edits'], 2)
        self.assertEqual(result['unscorable_pauses'], 1)
        self.assertEqual(result['scored_pauses'], 0)

    def test_insertions_at_pause_do_not_create_false_metric(self):
        result = score(self.case(), 'Please send the report um tomorrow.')
        self.assertEqual(result['word_edits'], 1)
        self.assertEqual(result['unscorable_pauses'], 1)

    def test_repetitions_are_preserved(self):
        result = score(self.case('It is very very good.', 4), 'It is very good.')
        self.assertEqual(result['word_edits'], 1)

class RegressionTests(unittest.TestCase):
    def test_skipped_service_is_not_a_passing_comparison(self):
        rows = [dict(case_id='a', repeat=0, profile=p, status='skipped') for p in ('legacy500', 'server1500')]
        self.assertTrue(regression_issues(rows, 'server1500'))

    def test_word_accuracy_cannot_hide_more_false_breaks(self):
        case = dict(reference='Please come tomorrow.', pauses=[dict(before_word=2, kind='thinking')])
        rows = [dict(case_id='a', repeat=0, profile=p, status='ok', audio_sha256='same', metrics=score(case, text))
                for p, text in [('legacy500', 'Please come tomorrow.'), ('server1500', 'Please come. Tomorrow.')]]
        self.assertTrue(any('false_sentence_breaks' in x for x in regression_issues(rows, 'server1500')))

if __name__ == '__main__': unittest.main()
