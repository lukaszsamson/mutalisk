Code.require_file("support/mutator_test_support.ex", __DIR__)
Code.require_file("support/fixture_oracle_helper.ex", __DIR__)

ExUnit.start(exclude: [:integration, :e2e, :golden_oracle])
