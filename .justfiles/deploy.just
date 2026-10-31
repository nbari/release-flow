# release-flow deploy module. Import from the repository's root justfile:
#   import '.justfiles/deploy.just'
# Requires just >= 1.27.0, bash, git >= 2.31, jq.

release_flow_deploy := 'bash ' + quote(parent_directory(source_directory()) / 'scripts' / 'release-deploy.sh') + ' --project-dir ' + quote(justfile_directory())

# Prepare and push a patch release candidate (test_base: test-only, production_base: production)
[group('release')]
deploy:
    @{{ release_flow_deploy }} patch

# Prepare and push a minor release candidate (test_base: test-only, production_base: production)
[group('release')]
deploy-minor:
    @{{ release_flow_deploy }} minor

# Prepare and push a major release candidate (test_base: test-only, production_base: production)
[group('release')]
deploy-major:
    @{{ release_flow_deploy }} major
