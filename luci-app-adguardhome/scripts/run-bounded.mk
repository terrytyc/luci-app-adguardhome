define AdGuardHome/RunBounded
run_bounded() (
	local limit="$$1" grace="$$2" marker="" child="" watchdog="" rc=0 expired=0
	shift 2
	case "$$limit" in ""|*[!0-9]*) exit 125 ;; esac
	case "$$grace" in ""|*[!0-9]*) exit 125 ;; esac
	[ "$$#" -gt 0 ] || exit 125
	[ -x /usr/bin/setsid ] || exit 125
	marker="$$(mktemp /tmp/luci-app-adguardhome-bounded.XXXXXX)" || exit 125
	chmod 0600 "$$marker" || {
		rm -f "$$marker"
		exit 125
	}
	printf '0\n' >"$$marker" || {
		rm -f "$$marker"
		exit 125
	}
	bounded_signal_session() {
		/bin/kill "-$$1" -- "-$$child" 2>/dev/null ||
			/bin/kill "-$$1" "$$child" 2>/dev/null || true
	}
	bounded_abort() {
		trap - HUP INT QUIT TERM
		[ -z "$$watchdog" ] || /bin/kill -TERM "$$watchdog" 2>/dev/null || true
		[ -z "$$watchdog" ] || wait "$$watchdog" 2>/dev/null || true
		if [ -n "$$child" ]; then
			bounded_signal_session TERM
			sleep "$$grace" 2>/dev/null || true
			bounded_signal_session KILL
			wait "$$child" 2>/dev/null || true
		fi
		rm -f "$$marker"
		exit 125
	}
	trap bounded_abort HUP INT QUIT TERM
	[ ! -e /proc/self/fd/187 ] || bounded_abort
	exec 187<&0 || bounded_abort
	/usr/bin/setsid "$$@" <&187 187<&- &
	child=$$!
	exec 187<&-
	(
		bounded_sleeper=""
		bounded_watchdog_abort() {
			trap - HUP INT QUIT TERM
			[ -z "$$bounded_sleeper" ] || /bin/kill -TERM "$$bounded_sleeper" 2>/dev/null || true
			[ -z "$$bounded_sleeper" ] || wait "$$bounded_sleeper" 2>/dev/null || true
			exit 1
		}
		bounded_watchdog_sleep() {
			sleep "$$1" &
			bounded_sleeper=$$!
			wait "$$bounded_sleeper"
			bounded_sleep_rc=$$?
			bounded_sleeper=""
			return "$$bounded_sleep_rc"
		}
		trap bounded_watchdog_abort HUP INT QUIT TERM
		bounded_watchdog_sleep "$$limit" || exit 1
		/bin/kill -0 -- "-$$child" 2>/dev/null || /bin/kill -0 "$$child" 2>/dev/null || exit 1
		printf '1\n' >"$$marker" || exit 1
		bounded_signal_session TERM
		bounded_watchdog_sleep "$$grace" || exit 0
		bounded_signal_session KILL
	) &
	watchdog=$$!
	wait "$$child" 2>/dev/null || rc=$$?
	read -r expired <"$$marker" 2>/dev/null || expired=0
	if [ "$$expired" = 1 ]; then
		wait "$$watchdog" 2>/dev/null || true
	else
		/bin/kill -TERM "$$watchdog" 2>/dev/null || true
		wait "$$watchdog" 2>/dev/null || true
	fi
	trap - HUP INT QUIT TERM
	rm -f "$$marker"
	[ "$$expired" = 1 ] && exit 124
	exit "$$rc"
)
endef
