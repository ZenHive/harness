%Doctor.Config{
  ignore_modules: [],
  ignore_paths: [],

  # Project standard: 100% documentation coverage on all public modules
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 100,
  min_overall_doc_coverage: 100,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 100,
  struct_type_spec_required: true,
  exception_moduledoc_required: true,
  raise: false,
  reporter: Doctor.Reporters.Full
}
