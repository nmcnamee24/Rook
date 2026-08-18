.PHONY: build test format lint check doctor app mobile relay skill check-skill wake enroll-wake record-wake-evaluation record-wake-negative train-wake evaluate-wake trial-wake promote-wake install

build:
	swift build

test:
	swift test

format:
	swift format format --in-place --recursive --parallel Sources Tests Mobile Package.swift

lint:
	swift format lint --strict --recursive --parallel Sources Tests Mobile Package.swift

check: lint test mobile relay
	@for file in scripts/*.sh; do /bin/zsh -n "$$file"; done
	@./scripts/check-version.sh
	@plutil -lint Resources/Info.plist Resources/com.noah.rook.login.plist
	@python3 -m py_compile scripts/evaluate_wake_word.py
	@python3 -m compileall -q Resources skill/rook/scripts
	@python3 -m json.tool skill/rook/assets/rook_flow_snippets.json >/dev/null

doctor:
	./scripts/doctor.sh

app:
	./scripts/build-app.sh

mobile:
	xcodebuild -quiet -project RookMobile.xcodeproj -scheme RookMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

relay:
	cd Relay && npm run check && npm test

skill:
	./scripts/install-skill.sh

check-skill:
	./scripts/install-skill.sh --check

wake:
	swift build -c release --product RookWakeTool

enroll-wake:
	./scripts/record-wake-corpus.sh

record-wake-evaluation:
	./scripts/record-wake-corpus.sh evaluation

record-wake-negative:
	./scripts/record-wake-negative.sh

train-wake:
	./scripts/train-livekit-wake.sh

evaluate-wake:
	./scripts/evaluate-wake-word.sh

trial-wake:
	./scripts/activate-wake-trial.sh

promote-wake:
	./scripts/promote-wake-model.sh

install: app
	./scripts/install.sh
