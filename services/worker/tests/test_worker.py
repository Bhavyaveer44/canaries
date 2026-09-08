from worker import process


def test_process_reverses_payload():
    assert process("abc") == "cba"


def test_process_handles_empty_string():
    assert process("") == ""
