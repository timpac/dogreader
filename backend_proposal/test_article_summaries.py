"""No cloud, provider, credentials, or paid requests used by these tests."""
import hashlib
import unittest

from article_summaries import (SYSTEM, SUMMARY_MODEL, SummaryError, SummaryService, request_id,
                               validate, vertex_payload)

TEXT = ('A small pilot found a possible reduction in travel time. The authors '
        'warn that the sample is small and does not establish causation. ' * 8)
SUMMARY = ('The authors argue for further controlled trials after a small pilot '
           'suggested shorter travel times. They caution that the sample is small '
           'and does not establish a causal effect.')
ENV = {'DOGREADER_SUMMARIES_ENABLED': '1', 'DOGREADER_SUMMARY_MODEL': SUMMARY_MODEL,
       'DOGREADER_SUMMARY_REGION': 'global',
       'DOGREADER_SUMMARY_INPUT_USD_PER_MILLION': '0.25',
       'DOGREADER_SUMMARY_OUTPUT_USD_PER_MILLION': '1.50'}


class MemoryStore:
    def __init__(self):
        self.values = {}

    def read(self, identity):
        return self.values.get(identity)

    def claim(self, identity, value):
        if identity in self.values:
            return False
        self.values[identity] = value
        return True

    def finish(self, identity, value):
        self.values[identity] = value


class SummariesTest(unittest.TestCase):
    def setUp(self):
        self.store = MemoryStore()
        self.calls = []

        def generate(*args):
            self.calls.append(args)
            return {'candidates': [{'finishReason': 'STOP', 'content': {
                'parts': [{'text': SUMMARY}]}}], 'usageMetadata': {
                    'promptTokenCount': 100, 'candidatesTokenCount': 50}}
        self.generate = generate
        self.api = SummaryService(self.store, generate, ENV)

    def test_estimates_all_depths_without_generation(self):
        caps = []
        for depth in ('brief', 'standard', 'detailed'):
            result = self.api.estimate({'text': TEXT, 'depth': depth})
            caps.append(result['maxOutputTokens'])
            self.assertGreater(result['estimatedCostUsd'], 0)
        self.assertEqual(caps, [512, 1024, 2048])
        self.assertEqual(self.calls, [])

    def test_unknown_prices_are_explicit(self):
        api = SummaryService(self.store, self.generate,
                             {k: v for k, v in ENV.items() if 'MILLION' not in k})
        self.assertIsNone(api.estimate({'text': TEXT, 'depth': 'brief'})['estimatedCostUsd'])

    def test_disabled_by_default_and_unapproved_model_rejected(self):
        for env in ({}, dict(ENV, DOGREADER_SUMMARY_MODEL='client-chosen-expensive-model'),
                    dict(ENV, DOGREADER_SUMMARY_MODEL='gemini-2.5-flash-lite')):
            with self.assertRaises(SummaryError) as caught:
                SummaryService(self.store, self.generate, env).estimate({'text': TEXT, 'depth': 'brief'})
            self.assertEqual(caught.exception.status, 503)

    def test_content_hash_and_input_validation(self):
        digest = hashlib.sha256(TEXT.encode()).hexdigest()
        self.assertEqual(validate({'text': TEXT, 'depth': 'brief', 'contentHash': digest}), (TEXT, 'brief'))
        for data in (None, {}, {'text': 'short', 'depth': 'brief'},
                     {'text': TEXT, 'depth': []}, {'text': TEXT, 'depth': 'extreme'},
                     {'text': TEXT, 'depth': 'brief', 'contentHash': 'incorrect'},
                     {'text': 'a' * 250001, 'depth': 'brief'}):
            with self.assertRaises(SummaryError):
                validate(data)

    def test_repeated_request_reuses_summary_and_usage(self):
        request = {'text': TEXT, 'depth': 'brief'}
        first = self.api.summarize(request)
        second = self.api.summarize(request)
        self.assertEqual(first, second)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(first['summary'], SUMMARY)
        self.assertAlmostEqual(first['usage']['costUsd'], 0.0001)

    def test_region_must_be_explicit_and_supported_without_fallback(self):
        for location in ('', 'us-central1'):
            api = SummaryService(self.store, self.generate, dict(ENV, DOGREADER_SUMMARY_REGION=location))
            with self.assertRaises(SummaryError):
                api.summarize({'text': TEXT, 'depth': 'brief'})
        self.assertEqual(self.calls, [])

    def test_identity_changes_with_text_depth_and_model(self):
        ids = [request_id(TEXT, 'brief', 'model'), request_id(TEXT + ' More.', 'brief', 'model'),
               request_id(TEXT, 'detailed', 'model'), request_id(TEXT, 'brief', 'other')]
        self.assertEqual(len(set(ids)), 4)

    def test_processing_claim_is_never_a_second_paid_call(self):
        identity = request_id(TEXT, 'brief', ENV['DOGREADER_SUMMARY_MODEL'])
        self.store.claim(identity, {'status': 'processing'})
        with self.assertRaises(SummaryError) as caught:
            self.api.summarize({'text': TEXT, 'depth': 'brief'})
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(self.calls, [])

    def test_provider_timeout_is_claimed_without_automatic_retry(self):
        calls = []
        def timeout(*args):
            calls.append(args)
            raise TimeoutError('could have been billed')
        api = SummaryService(self.store, timeout, ENV)
        for _ in range(2):
            with self.assertRaises(SummaryError):
                api.summarize({'text': TEXT, 'depth': 'brief'})
        self.assertEqual(len(calls), 1)

    def test_truncated_blocked_and_short_outputs_are_not_saved_as_ready(self):
        for response in ({'candidates': []}, {'candidates': [{'finishReason': 'MAX_TOKENS'}]},
                         {'candidates': [{'finishReason': 'STOP', 'content': {'parts': [{'text': 'Too short'}]}}]}):
            api = SummaryService(MemoryStore(), lambda *args: response, ENV)
            with self.assertRaises(SummaryError) as caught:
                api.summarize({'text': TEXT, 'depth': 'brief'})
            self.assertEqual(caught.exception.status, 422)

    def test_output_storage_failure_does_not_repeat_provider(self):
        class BrokenFinish(MemoryStore):
            def finish(self, identity, value):
                raise OSError('storage interrupted')
        api = SummaryService(BrokenFinish(), self.generate, ENV)
        for _ in range(2):
            with self.assertRaises(SummaryError):
                api.summarize({'text': TEXT, 'depth': 'brief'})
        self.assertEqual(len(self.calls), 1)

    def test_prompt_preserves_qualifications_and_treats_input_as_data(self):
        for phrase in ('untrusted data', 'central argument', 'qualifications',
                       'Do not invent', 'outside facts', 'correlation into causation'):
            self.assertIn(phrase, SYSTEM)

    def test_verified_model_payload_preserves_exact_source_and_disables_tools(self):
        text = TEXT + '\n\n😀 e\u0301  \n'
        payload = vertex_payload(text, 'brief', 512)
        self.assertTrue(payload['contents'][0]['parts'][0]['text'].endswith(text))
        config = payload['generationConfig']
        self.assertEqual(config['thinkingConfig'], {'thinkingLevel': 'MINIMAL'})
        self.assertNotIn('thinkingBudget', config['thinkingConfig'])
        self.assertNotIn('tools', payload)
        self.assertEqual(config['maxOutputTokens'], 512)

    def test_split_provider_text_parts_are_not_rewritten(self):
        response = self.generate(TEXT, 'brief', SUMMARY_MODEL, 512)
        response['candidates'][0]['content']['parts'] = [
            {'text': SUMMARY[:70]}, {'text': 'internal reasoning', 'thought': True},
            {'text': SUMMARY[70:] + '\n\n  😀 e\u0301  '}]
        api = SummaryService(self.store, lambda *args: response, ENV)
        self.assertEqual(api.summarize({'text': TEXT, 'depth': 'brief'})['summary'],
                         SUMMARY + '\n\n  😀 e\u0301  ')


if __name__ == '__main__':
    unittest.main()
