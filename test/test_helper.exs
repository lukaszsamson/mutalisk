Code.require_file("support/mutator_test_support.ex", __DIR__)
Code.require_file("support/fixture_oracle_helper.ex", __DIR__)
Code.require_file("support/fallback_fixture.ex", __DIR__)
Code.require_file("support/mutator/always_wrong.ex", __DIR__)
Code.require_file("support/coverage_parser_fixture.ex", __DIR__)

ExUnit.start(exclude: [:integration, :e2e, :golden_oracle, :golden_instrument])
