# garrett, the agent of sentinels, for Fedora, RHEL and their relatives, and openSUSE (dnf, yum, zypper).
#
# It packs the program files the release workflow built, from the release's Linux bundles: nothing is compiled
# here. packaging/build-packages.sh builds one package for each processor, on any machine with rpmbuild:
#   rpmbuild -bb --target x86_64 --define "garrett_version 1.9.2" --define "garrett_bundle garrett-linux-x86_64.tar.gz" garrett.spec
#
# Like most packages with a service on these systems, it does not start garrett by itself:
#   systemctl enable --now garrett
Name:           garrett
Version:        %{garrett_version}
Release:        1
Summary:        sentinels agent: host intrusion sentinel that stops what it catches
License:        MIT
URL:            https://github.com/gary23w/sentinels
Source0:        %{garrett_bundle}
# Without ss garrett still ends hostile programs as they start; it cannot see who a program talks to.
Recommends:     (iproute or iproute2)
# Fleet blocking refuses the addresses your service names at the firewall, with nftables.
Recommends:     nftables

# The program file is statically linked and already stripped: nothing to strip, no debug package, no build ids.
%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

# The alias: dnf install sentinels (and zypper install sentinels) installs garrett. It has no files of its own.
%package -n sentinels
Summary:        sentinels host intrusion detection and response (installs garrett)
BuildArch:      noarch
Requires:       garrett >= %{version}

%description -n sentinels
sentinels is open-source host intrusion detection and response. Its agent,
garrett, watches this machine's running programs and their connections and
ends a program it judges hostile. This package installs garrett, which does
the work: remove garrett to remove both.

%description
garrett, the agent of sentinels, watches this machine's running programs and
their connections, scores them on the machine, and pauses or ends a program
it judges hostile.

It reports cases to a Sentinel service you run yourself, applies what that
service learned from earlier attacks, and shares what one machine learns
with the rest of your machines.

%prep
%setup -q -n garrett

%build

%install
install -Dm0755 garrett-agent %{buildroot}/usr/lib/garrett/garrett-agent
install -Dm0755 unblock %{buildroot}/usr/lib/garrett/unblock
install -Dm0755 garrett %{buildroot}/usr/bin/garrett
install -Dm0644 garrett.service %{buildroot}/usr/lib/systemd/system/garrett.service
install -Dm0644 garrett.8 %{buildroot}/usr/share/man/man8/garrett.8
install -Dm0644 LICENSE %{buildroot}/usr/share/licenses/garrett/LICENSE
install -Dm0644 NOTICES.md %{buildroot}/usr/share/doc/garrett/NOTICES.md

%files
/usr/lib/garrett
/usr/bin/garrett
/usr/lib/systemd/system/garrett.service
/usr/share/man/man8/garrett.8
/usr/share/licenses/garrett
/usr/share/doc/garrett

%files -n sentinels

%post
systemctl daemon-reload >/dev/null 2>&1 || :
if [ "$1" -eq 1 ]; then
  echo "garrett is installed. Start it now and at every boot:  systemctl enable --now garrett"
  echo "Then see what it finds:  garrett cases"
fi

%preun
# Removed, not upgraded: stopped while its files are still there, so whatever addresses it refused are let through.
if [ "$1" -eq 0 ]; then
  systemctl disable --now garrett.service >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :
if [ "$1" -ge 1 ]; then
  # Upgraded: the new version takes over from the running one, as the Debian package does.
  systemctl try-restart garrett.service >/dev/null 2>&1 || :
else
  # The one firewall table garrett owns goes with it.
  if command -v nft >/dev/null 2>&1; then nft delete table inet garrett 2>/dev/null || :; fi
  # So does what it kept, as with the bundle's install.sh --remove: its cases, its enrolment credential, and the
  # configuration file that may hold an enrolment key.
  rm -rf /var/lib/garrett /etc/garrett
fi
