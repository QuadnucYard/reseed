# Shared test helpers. Both test scripts import the assertion commands from
# here so failure formatting stays in one place.

use std assert

# Fail the test run unless the actual value equals the expected one.
export def "assert eq" [
  actual: any # Value produced by the code under test.
  expected: any # Value the test expects.
  label: string # Description shown when the assertion fails.
] {
  assert ($actual == $expected) $"($label): expected ($expected | to nuon), got ($actual | to nuon)"
}

# Fail the test run unless the actual value differs from the expected one.
export def "assert ne" [
  actual: any # Value produced by the code under test.
  expected: any # Value the test expects to differ.
  label: string # Description shown when the assertion fails.
] {
  assert ($actual != $expected) $"($label): expected a value different from ($expected | to nuon), got ($actual | to nuon)"
}
