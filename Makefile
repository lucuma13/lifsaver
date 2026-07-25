.DEFAULT_GOAL := help
.PHONY: upgrade pre-commit test run render install uninstall reinstall clean help

# The .app/.pkg product name
APP := Lifsaver

upgrade: ## Upgrade dependencies
	swift package update

pre-commit: ## Run all pre-commit hooks
	pre-commit run --all-files

test: ## Run the test suite
	swift test --enable-code-coverage
	./scripts/coverage.sh

run: ## Build and run the debug executable (unbundled) for quick iteration
	swift run

render: ## Regenerate committed visual assets (icons, social preview, demo GIF)
	./scripts/render/icons.sh
	./scripts/render/social_preview.sh
	swift scripts/render/demo_animation.swift

install: ## Build, assemble, and install the app to /Applications
	./scripts/release/build.sh
	./scripts/release/bundle_app.sh
	./scripts/release/make_pkg.sh
	rm -rf /Applications/$(APP).app
	mv ./dist/$(APP).app /Applications/

uninstall: ## Quit and remove the installed app from /Applications
	-pkill -x $(APP)
	rm -rf /Applications/$(APP).app

reinstall: ## Uninstall any previous copy, then install fresh
	$(MAKE) uninstall
	$(MAKE) install

clean: ## Remove build artifacts
	rm -rf .build dist
	rm -f coverage.lcov

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-11s\033[0m %s\n", $$1, $$2}'
