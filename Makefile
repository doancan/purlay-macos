# The stable entry point. scripts/verify holds the lanes; nothing is decided here.
#
#   make setup            the pinned tools (XcodeGen, gitleaks), from their releases, checked against pinned digests
#   make verify           what a pull request needs: rules, format and tests, the Debug app
#   make verify-security  the history scanned for secrets
#   make verify-all       every lane, with the Release build too (what a release runs)
.PHONY: setup verify verify-security verify-all

setup:
	scripts/install-xcodegen
	scripts/install-gitleaks

verify:
	scripts/verify rules
	scripts/verify test
	scripts/verify app

verify-security:
	scripts/verify security

verify-all:
	scripts/verify
