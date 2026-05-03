%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: [
          "_build/",
          "deps/",
          "test/fixtures/demo_app/_build/",
          "test/fixtures/demo_app/deps/"
        ]
      },
      strict: true,
      checks: []
    }
  ]
}
