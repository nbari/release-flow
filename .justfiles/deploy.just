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

release_flow_scripts := parent_directory(source_directory()) / 'scripts'

# Promote a validated production candidate: signed tag plus one atomic push of main, develop and the tag (--dry-run: preflight only)
[group('release')]
release-promote candidate commit *flags:
    @bash {{ quote(release_flow_scripts / 'release-promote.sh') }} --project-dir {{ quote(justfile_directory()) }} --candidate {{ quote(candidate) }} --commit {{ quote(commit) }} {{ flags }}

# Show the release state of a version and its publication channels (--json for machines)
[group('release')]
release-status version *flags:
    @bash {{ quote(release_flow_scripts / 'release-status.sh') }} --project-dir {{ quote(justfile_directory()) }} {{ quote(version) }} {{ flags }}

# Re-publish one channel of a promoted version with current publisher code (--local, --ref REF, --break-lock)
[group('release')]
release-retry version channel *flags:
    @bash {{ quote(release_flow_scripts / 'release-retry.sh') }} --project-dir {{ quote(justfile_directory()) }} {{ quote(version) }} {{ quote(channel) }} {{ flags }}
