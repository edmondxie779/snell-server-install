"""Safe local regression tests; never execute main() or real systemctl/openrc/userdel."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "install-snell.sh"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.conf = self.root / "snell"
        self.conf.mkdir()
        self.binary = self.root / "snell-server"
        self.binary.write_text("old-valid-binary\n")
        self.unit = self.root / "snell.service"
        self.unit.write_text("old-service\n")
        self.openrc = self.root / "snell.openrc"
        self.log_dir = self.root / "log"
        self.log_dir.mkdir()
        self.openrc_log = self.log_dir / "snell.log"
        self.config = self.conf / "snell-server.conf"
        self.config.write_text("[snell-server]\nlisten = 0.0.0.0:32568\npsk = test-only-key\nipv6 = false\n")
        self.proxy = self.conf / "surge-proxy.txt"
        self.proxy.write_text("old-node\n")
        self.source = self.root / "new-binary"
        self.source.write_text("new-invalid-binary\n")
        # Only function definitions. All privileged absolute locations are redirected.
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        source = source.replace("readonly BIN=/usr/local/bin/snell-server", 'readonly BIN="$TEST_ROOT/snell-server"')
        source = source.replace("readonly CONF_DIR=/etc/snell", 'readonly CONF_DIR="$TEST_ROOT/snell"')
        source = source.replace("readonly UNIT=/etc/systemd/system/snell.service", 'readonly UNIT="$TEST_ROOT/snell.service"')
        source = source.replace("readonly OPENRC_INIT=/etc/init.d/snell", 'readonly OPENRC_INIT="$TEST_ROOT/snell.openrc"')
        source = source.replace("readonly OPENRC_LOG_DIR=/var/log/snell", 'readonly OPENRC_LOG_DIR="$TEST_ROOT/log"')
        source = source.replace("readonly OPENRC_LOG=/var/log/snell/snell.log", 'readonly OPENRC_LOG="$TEST_ROOT/log/snell.log"')
        source = source.replace("/var/backups/snell", self.temp.name + "/backups")
        self.definitions = source + r'''
systemctl() {
    printf '%s\n' "$*" >> "$TEST_ROOT/systemctl.log"
    case "$1" in
        show)
            case "$*" in
                *LoadState*) echo "${MOCK_LOAD_STATE:-loaded}" ;;
                *ExecStart*) printf '{ path=%s ; argv[]=%s -c %s ; }\n' "${MOCK_BINARY_PATH:-$BIN}" "$BIN" "${MOCK_CONFIG_PATH:-$CONF_DIR/snell-server.conf}" ;;
            esac ;;
        is-enabled) echo "${MOCK_ENABLED_STATE:-enabled}" ;;
        is-active) [[ ${MOCK_ACTIVE_STATE:-active} == active ]] ;;
        start) ! grep -q 'invalid' "$BIN" ;;
        cat) printf 'effective service\n' ;;
        *) return 0 ;;
    esac
}
rc-service() {
    printf '%s\n' "$*" >> "$TEST_ROOT/rc-service.log"
    if [[ $1 == -e ]]; then
        [[ -e $OPENRC_INIT ]]
        return
    fi
    case "$2" in
        status) [[ ${MOCK_OPENRC_ACTIVE:-active} == active ]] ;;
        start) ! grep -q 'invalid' "$BIN" ;;
        *) return 0 ;;
    esac
}
rc-update() {
    printf '%s\n' "$*" >> "$TEST_ROOT/rc-update.log"
    if [[ $1 == show ]]; then
        if [[ ${MOCK_OPENRC_ENABLED:-enabled} == enabled ]]; then
            printf '               snell | default\n'
        fi
    fi
    return 0
}
userdel() { printf '%s\n' "$*" >> "$TEST_ROOT/userdel.log"; }
deluser() { printf '%s\n' "$*" >> "$TEST_ROOT/deluser.log"; }
delgroup() { printf '%s\n' "$*" >> "$TEST_ROOT/delgroup.log"; }
if [[ $(uname -s) == Darwin ]]; then
    file_identity() { stat -f '%d:%i' "$1"; }
fi
'''

    def run_shell(self, commands, expect=0, stdin_text=None):
        result = subprocess.run(
            ["bash", "-c", self.definitions + commands],
            env=dict(os.environ, TEST_ROOT=str(self.root)),
            input=stdin_text,
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return result

    def write_os_release(self, os_id, version_id):
        path = self.root / "os-release"
        path.write_text(f'ID="{os_id}"\nVERSION_ID="{version_id}"\n')
        return path

    def test_reinstall_preserves_config(self):
        original = self.config.read_bytes()
        self.run_shell(r'''
prepare_reinstall
[[ $REUSE_CONFIG == 1 && $REUSE_UNIT == 1 ]]
[[ $OLD_PORT == 32568 && $OLD_PSK == test-only-key ]]
[[ -z $NODE_EXTRA ]]
''')
        self.assertEqual(self.config.read_bytes(), original)

    def test_http_obfuscation_and_crlf(self):
        self.config.write_bytes(b"[snell-server]\r\nlisten = [::]:443\r\npsk = test-key==\r\nobfs = http\r\n")
        out = self.run_shell(r'''
prepare_reinstall
[[ $OLD_PORT == 443 && $OLD_PSK == test-key== ]]
show_result 203.0.113.10 "$OLD_PORT" "$OLD_PSK"
''').stdout
        self.assertIn("我的VPS = snell, 203.0.113.10, 443, psk=test-key==, version=5, obfs=http\n", out)
        self.assertNotIn("\x1b", out)

    def test_backup_replace_and_failed_start_restores_old_install(self):
        old = {p: p.read_bytes() for p in (self.binary, self.config, self.unit, self.proxy)}
        extra = self.conf / "unrelated.txt"
        extra.write_text("keep")
        self.run_shell(r'''
REINSTALL=1
prepare_reinstall
backup_install
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
printf 'new-node\n' > "$TEST_ROOT/new-node"
create_file "$TEST_ROOT/new-node" "$CONF_DIR/surge-proxy.txt" 600
systemctl start snell.service
''', expect=1)
        for path, content in old.items():
            self.assertEqual(path.read_bytes(), content)
        self.assertEqual(extra.read_text(), "keep")
        self.assertFalse((self.root / "userdel.log").exists())
        self.assertEqual(len(list((self.root / "backups").glob("backup-*"))), 1)
        self.assertGreaterEqual((self.root / "systemctl.log").read_text().count("start snell.service"), 2)

    def test_successful_replace_retains_backup(self):
        self.source.write_text("new-valid-binary\n")
        self.run_shell(r'''
REINSTALL=1
prepare_reinstall
backup_install
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
systemctl start snell.service
DONE=1
''')
        self.assertEqual(self.binary.read_text(), "new-valid-binary\n")
        backups = list((self.root / "backups").glob("backup-*/snell-server"))
        self.assertEqual(backups[0].read_text(), "old-valid-binary\n")
        self.assertEqual(self.proxy.read_text(), "old-node\n")

    def test_failed_reinstall_does_not_start_previously_stopped_service(self):
        self.run_shell(r'''
REINSTALL=1
backup_install
OLD_ACTIVE=0
OLD_ENABLED=disabled
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
exit 1
''', expect=1)
        log = (self.root / "systemctl.log").read_text()
        self.assertNotIn("start snell.service", log)
        self.assertNotIn("disable snell.service", log)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_backup_and_restore_permissions(self):
        self.binary.chmod(0o750)
        self.run_shell(r'''
REINSTALL=1
backup_install
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
exit 1
''', expect=1)
        self.assertEqual(self.binary.stat().st_mode & 0o777, 0o750)
        backup = next((self.root / "backups").glob("backup-*"))
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)

    def test_unbacked_file_cannot_be_overwritten(self):
        self.run_shell('create_file "$TEST_ROOT/new-binary" "$BIN" 755\n', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_changed_after_backup_cannot_be_overwritten(self):
        self.run_shell(r'''
REINSTALL=1
backup_install
printf 'external change\n' > "$BIN"
create_file "$TEST_ROOT/new-binary" "$BIN" 755
''', expect=1)
        self.assertEqual(self.binary.read_text(), "external change\n")

    def test_new_install_failure_removes_only_new_resources(self):
        self.binary.unlink()
        self.unit.unlink()
        self.proxy.unlink()
        self.run_shell(r'''
CREATED=1
USER_CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
exit 1
''', expect=1)
        self.assertFalse(self.binary.exists())
        self.assertTrue(self.config.exists())
        self.assertEqual((self.root / "userdel.log").read_text(), "snell-auto\n")

    def test_no_file_changes_failure_keeps_old_service(self):
        self.run_shell(r'''
REINSTALL=1
backup_install
CREATED=1
exit 1
''', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")
        self.assertIn("start snell.service", (self.root / "systemctl.log").read_text())

    def test_symlink_is_not_overwritten(self):
        self.binary.unlink()
        self.binary.symlink_to(self.source)
        self.run_shell('prepare_reinstall\n', expect=1)
        self.assertTrue(self.binary.is_symlink())

    def test_similar_binary_path_is_not_accepted(self):
        self.run_shell('MOCK_BINARY_PATH="$BIN-old"\nprepare_reinstall\n', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_similar_config_path_is_not_accepted(self):
        self.run_shell('MOCK_CONFIG_PATH="$CONF_DIR/snell-server.conf.other"\nprepare_reinstall\n', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_missing_unit_is_rejected_before_transaction(self):
        self.run_shell('MOCK_LOAD_STATE=not-found\nprepare_reinstall\n', expect=1)
        log = (self.root / "systemctl.log").read_text()
        self.assertNotIn("stop snell.service", log)
        self.assertNotIn("disable snell.service", log)

    def test_rollback_preserves_file_created_by_other_process(self):
        out = self.run_shell(r'''
REINSTALL=1
backup_install
CREATED=1
rm() {
    command rm "$@"
    if [[ $* == "-- $BIN" ]]; then
        printf 'other-process-file\n' > "$BIN"
    fi
}
create_file "$TEST_ROOT/new-binary" "$BIN" 755
''', expect=1)
        self.assertEqual(self.binary.read_text(), "other-process-file\n")
        self.assertIn("文件被其他程序替换，未删除", out.stderr)
        backup = next((self.root / "backups").glob("backup-*/snell-server"))
        self.assertEqual(backup.read_text(), "old-valid-binary\n")

    def test_custom_listener_is_rejected_without_changes(self):
        self.config.write_text("[snell-server]\nlisten = 127.0.0.1:1234\npsk = example\n")
        self.run_shell('prepare_reinstall\n', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_parse_args_and_version_formats(self):
        out = self.run_shell(r'''
parse_args --version 4 --yes
[[ $SNELL_MAJOR == 4 && $SNELL_VERSION == 4.1.1 && $AUTO_YES == 1 ]]
show_result 203.0.113.10 23456 mypsk
''').stdout
        self.assertIn("Snell v4（服务端 4.1.1）", out)
        self.assertIn("我的VPS = snell, 203.0.113.10, 23456, psk=mypsk, version=4\n", out)

        out_v6 = self.run_shell(r'''
parse_args -v 6 --mode unshaped
[[ $SNELL_MAJOR == 6 && $SNELL_VERSION == 6.0.0 && $CLI_MODE == unshaped ]]
SNELL_MODE=$CLI_MODE
NODE_EXTRA=", mode=${SNELL_MODE}"
show_result 203.0.113.10 34567 mypsk
''').stdout
        self.assertIn("Snell v6（服务端 6.0.0 · Beta（mode=unshaped））", out_v6)
        self.assertIn("我的VPS = snell, 203.0.113.10, 34567, psk=mypsk, version=6, mode=unshaped\n", out_v6)

        self.run_shell('parse_args --version 5 --mode unshaped\n', expect=1)
        self.run_shell('parse_args --version 9\n', expect=1)
        self.run_shell('parse_args --mode invalid\n', expect=1)

    def test_v6_multilistener_supported_and_v5_rejects_multilistener(self):
        self.config.write_text("[snell-server]\nlisten = 0.0.0.0:41000, [::]:41000\npsk = v6-key\nmode = unsafe-raw\n")
        out = self.run_shell(r'''
set_snell_version 6
prepare_reinstall
[[ $OLD_PORT == 41000 && $SNELL_MODE == unsafe-raw ]]
show_result 203.0.113.10 "$OLD_PORT" "$OLD_PSK"
''').stdout
        self.assertIn("我的VPS = snell, 203.0.113.10, 41000, psk=v6-key, version=6, mode=unsafe-raw\n", out)

        self.run_shell('set_snell_version 5\nprepare_reinstall\n', expect=1)

        self.config.write_text("[snell-server]\nlisten = 0.0.0.0:41000, [::]:41001\npsk = v6-key\n")
        self.run_shell('set_snell_version 6\nprepare_reinstall\n', expect=1)

    def test_v5_obfs_upgrade_to_v6_auto_removes_and_rolls_back_on_failure(self):
        raw_conf = "[snell-server]\nlisten = 0.0.0.0:32568\npsk = test-only-key\nobfs = http\nobfs-host = example.com\nipv6 = false\n"
        self.config.write_text(raw_conf)
        self.run_shell(r'''
set_snell_version 6
REINSTALL=1
prepare_reinstall
[[ $REMOVE_OBFS == 1 && $REMOVE_OBFS_CONFIRMED == 1 ]]
backup_install
CREATED=1
WORK=$(mktemp -d)
rewrite_config_for_v6 "$CONF_DIR/snell-server.conf" "$WORK/snell-server.conf" "$REMOVE_OBFS" "$UPDATE_MODE" "$SNELL_MODE"
create_file "$WORK/snell-server.conf" "$CONF_DIR/snell-server.conf" 640
grep -q '^ipv6 = false$' "$CONF_DIR/snell-server.conf"
! grep -q '^obfs' "$CONF_DIR/snell-server.conf"
create_file "$TEST_ROOT/new-binary" "$BIN" 755
svc_start
''', expect=1, stdin_text="yes\n")
        # Full rollback restores original config including obfs = http.
        self.assertEqual(self.config.read_text(), raw_conf)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")

    def test_v5_obfs_upgrade_to_v6_no_cancels_cleanly(self):
        raw_conf = "[snell-server]\nlisten = 0.0.0.0:32568\npsk = test-only-key\nobfs = http\n"
        self.config.write_text(raw_conf)
        out = self.run_shell(r'''
set_snell_version 6
REINSTALL=1
prepare_reinstall
''', expect=0, stdin_text="no\n").stdout
        self.assertIn("已取消", out)
        self.assertEqual(self.config.read_text(), raw_conf)

    def test_v6_settings_downgrade_to_v5_rejected(self):
        self.config.write_text("[snell-server]\nlisten = 0.0.0.0:32568\npsk = key\nmode = unshaped\n")
        self.run_shell('set_snell_version 5\nprepare_reinstall\n', expect=1)

        self.config.write_text("[snell-server]\nlisten = 0.0.0.0:32568\npsk = key\ndns-ip-preference = prefer-ipv4\n")
        self.run_shell('set_snell_version 4\nprepare_reinstall\n', expect=1)

    def test_detect_platform_supported_and_rejected_distros(self):
        systemd_dir = self.root / "run-systemd"
        systemd_dir.mkdir()
        openrc_dir = self.root / "run-openrc"
        openrc_dir.mkdir()
        bin_dir = self.root / "mock-bin"
        bin_dir.mkdir()
        for tool in ("systemctl", "rc-service", "rc-update"):
            p = bin_dir / tool
            p.write_text("#!/bin/sh\nexit 0\n")
            p.chmod(0o755)

        for os_id, ver, family, mgr, init_sys in [
            ("debian", "11", "debian", "apt", "systemd"),
            ("ubuntu", "24.04", "debian", "apt", "systemd"),
            ("almalinux", "9.4", "rhel", "dnf", "systemd"),
            ("rocky", "8.10", "rhel", "dnf", "systemd"),
            ("centos", "9", "rhel", "dnf", "systemd"),
            ("alpine", "3.20.3", "alpine", "apk", "openrc"),
            ("alpine", "3.16.0", "alpine", "apk", "openrc"),
        ]:
            os_rel = self.write_os_release(os_id, ver)
            self.run_shell(f'''
PATH="{bin_dir}:$PATH"
OS_RELEASE_FILE="{os_rel}"
SYSTEMD_RUN_DIR="{systemd_dir}"
OPENRC_RUN_DIR="{openrc_dir}"
detect_platform
[[ $OS_FAMILY == "{family}" && $PKG_MGR == "{mgr}" && $INIT_SYS == "{init_sys}" ]]
''')

        for os_id, ver in [
            ("debian", "10"),
            ("ubuntu", "20.04"),
            ("almalinux", "7"),
            ("rocky", "7"),
            ("centos", "8"),
            ("alpine", "3.15.9"),
            ("arch", "rolling"),
        ]:
            os_rel = self.write_os_release(os_id, ver)
            self.run_shell(f'''
PATH="{bin_dir}:$PATH"
OS_RELEASE_FILE="{os_rel}"
SYSTEMD_RUN_DIR="{systemd_dir}"
OPENRC_RUN_DIR="{openrc_dir}"
detect_platform
''', expect=1)

        # Reject container-like environments missing active init run dirs.
        alpine_rel = self.write_os_release("alpine", "3.20.0")
        self.run_shell(f'''
PATH="{bin_dir}:$PATH"
OS_RELEASE_FILE="{alpine_rel}"
SYSTEMD_RUN_DIR="{self.root}/missing-systemd"
OPENRC_RUN_DIR="{self.root}/missing-openrc"
detect_platform
''', expect=1)

    def test_openrc_reinstall_and_rollback(self):
        self.unit.unlink()
        self.openrc.write_text(
            f'#!/sbin/openrc-run\ncommand="{self.binary}"\ncommand_args="-c {self.conf}/snell-server.conf"\n'
        )
        self.openrc.chmod(0o755)
        old_openrc = self.openrc.read_bytes()
        self.run_shell(r'''
OS_FAMILY=alpine
INIT_SYS=openrc
SERVICE_FILE=$OPENRC_INIT
REINSTALL=1
set_snell_version 6
prepare_reinstall
[[ $REUSE_CONFIG == 1 && $REUSE_UNIT == 1 ]]
backup_install
CREATED=1
create_file "$TEST_ROOT/new-binary" "$BIN" 755
svc_start
''', expect=1)
        self.assertEqual(self.binary.read_text(), "old-valid-binary\n")
        self.assertEqual(self.openrc.read_bytes(), old_openrc)
        self.assertEqual(self.openrc.stat().st_mode & 0o777, 0o755)
        rc_log = (self.root / "rc-service.log").read_text()
        self.assertIn("snell stop", rc_log)
        self.assertIn("snell start", rc_log)

    def test_openrc_new_service_definition_and_failure_cleanup(self):
        self.binary.unlink()
        self.unit.unlink()
        self.config.unlink()
        self.proxy.unlink()
        self.run_shell(r'''
OS_FAMILY=alpine
INIT_SYS=openrc
SERVICE_FILE=$OPENRC_INIT
set_snell_version 5
CREATED=1
USER_CREATED=1
WORK=$(mktemp -d)
write_service_definition "$WORK/snell.openrc"
create_file "$WORK/snell.openrc" "$SERVICE_FILE" 755
grep -Fq 'supervisor="supervise-daemon"' "$SERVICE_FILE"
grep -Fq 'command_user="snell-auto:snell-auto"' "$SERVICE_FILE"
ENABLE_CHANGED=1
svc_enable
exit 1
''', expect=1)
        self.assertFalse(self.openrc.exists())
        self.assertEqual((self.root / "deluser.log").read_text(), "snell-auto\n")
        self.assertIn("del snell default", (self.root / "rc-update.log").read_text())

    def test_dash_posix_bootstrap_help(self):
        result = subprocess.run(
            ["dash", str(SCRIPT), "--help"],
            text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("--version", result.stdout)
        self.assertIn("--mode", result.stdout)


if __name__ == "__main__":
    unittest.main()
