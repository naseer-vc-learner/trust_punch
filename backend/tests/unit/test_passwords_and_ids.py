"""Password policy, hashing, tokens and ids, without the web layer."""

import uuid

import pytest

from app.core import security
from app.core.ids import new_id
from app.modules.users.service import password_problems


@pytest.mark.parametrize(
    "password",
    ["correct horse battery", "Tr0ub4dor&3-extra-long", "مرحبا بالعالم الجميل", "पासवर्ड-बहुत-लंबा"],
)
def test_good_passwords_pass(password):
    assert password_problems(password, "asha") == []


@pytest.mark.parametrize(
    ("password", "reason"),
    [
        ("short", "at least 12"),
        ("x" * 129, "at most 128"),
        ("Password1234", "too common"),
        ("pass word 1234", "too common"),
        ("zzzzzzzzzzzzzz", "repeat one character"),
        ("abcdefghijklmn", "simple sequence"),
        ("zyxwvutsrqponm", "simple sequence"),
        ("123456789012345", "simple sequence"),
        ("098765432109876", "simple sequence"),
        ("i-am-asha-from-gate-a", "username"),
    ],
)
def test_bad_passwords_say_why(password, reason):
    problems = password_problems(password, "asha")
    assert any(reason in p for p in problems), problems


def test_hashes_are_argon2id_and_salted():
    a = security.hash_password("correct horse battery")
    b = security.hash_password("correct horse battery")
    assert a.startswith("$argon2id$") and a != b
    assert security.verify_password(a, "correct horse battery")
    assert not security.verify_password(a, "correct horse batterY")
    assert not security.verify_password("not-a-hash", "anything")


def test_tokens_are_prefixed_random_and_hashable():
    t1, t2 = security.new_token("tp_at_"), security.new_token("tp_at_")
    assert t1.startswith("tp_at_") and t1 != t2 and len(t1) >= 40
    assert len(security.token_hash(t1)) == 64


def test_ids_are_uuid7_and_time_ordered():
    ids = [new_id() for _ in range(50)]
    assert all(uuid.UUID(i).version == 7 for i in ids)
    assert ids == sorted(ids)
