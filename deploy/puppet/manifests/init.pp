# @summary garrett, the agent of sentinels, from the project's signed apt and rpm repositories.
#
# Installs garrett on Debian, Ubuntu, Fedora, RHEL and openSUSE the way the project's own instructions do, starts it
# at every boot, and enrols the machine with your Sentinel service if you give it one.
#
# @example A machine that protects itself
#   include garrett
#
# @example A machine that reports to your service, in report mode
#   class { 'garrett':
#     server     => 'https://sentinel.example.org',
#     enroll_key => Sensitive(lookup('garrett_enroll_key')),
#     mode       => 'report',
#   }
#
# @param server
#   Your Sentinel service. Give it with enroll_key, or leave both out and the machine protects itself by itself.
# @param enroll_key
#   The enrolment key the service gave you, best as a Sensitive value. Anyone who has it can add a machine.
# @param mode
#   What garrett does with a hostile program: kill (garrett's default), decide, pause or report.
# @param label
#   The name the machine enrols under. garrett's default is the host name.
# @param manage_service
#   Start garrett now and at every boot, and restart it when its settings change. False leaves the service alone,
#   for an image that starts it on its first boot; the machine enrols when garrett first starts.
# @param repository
#   Where the project's apt and rpm repositories are.
# @param apt_key_sha256
#   The SHA-256 of the apt signing key, garrett.gpg: the one packaging/install.sh pins.
# @param key_fingerprint
#   The fingerprint of the key that signs the rpm repository, as the project's README gives it.
class garrett (
  Optional[String[1]] $server = undef,
  Optional[Variant[String[1], Sensitive[String]]] $enroll_key = undef,
  Optional[Enum['kill', 'decide', 'pause', 'report']] $mode = undef,
  Optional[String[1]] $label = undef,
  Boolean $manage_service = true,
  String[1] $repository = 'https://gary23w.github.io/sentinels',
  Pattern[/\A[0-9a-f]{64}\z/] $apt_key_sha256 = '1f298d4106a58461a4a16d8976db87e8c5f581a20df180de1f69b73f1a69fa9d',
  Pattern[/\A[0-9A-F]{40}\z/] $key_fingerprint = '6857EBCBBEF51040C3F20107362688BFC238AB45',
) {
  $family = $facts['os']['family']
  unless $family in ['Debian', 'RedHat', 'Suse'] {
    fail("garrett: this module installs garrett on Debian, Ubuntu, Fedora, RHEL and openSUSE, not on ${family}. See https://github.com/gary23w/sentinels#setup.")
  }
  if ($server =~ Undef) != ($enroll_key =~ Undef) {
    fail('garrett: give server and enroll_key together, or neither.')
  }
  $key = $enroll_key ? {
    Sensitive => $enroll_key.unwrap,
    default   => $enroll_key,
  }
  if "${server}${key}${label}" =~ /[\r\n]/ {
    fail('garrett: no setting may span lines.')
  }

  $path = ['/usr/sbin', '/usr/bin', '/sbin', '/bin']
  $restart = $manage_service ? {
    true    => Service['garrett'],
    default => undef,
  }

  # The configuration goes down first, as packaging/install.sh writes it, so that garrett finds it the moment it
  # starts: with SERVER and ENROLL_KEY in it, "garrett auto" enrols the machine before the service runs.
  if $server =~ NotUndef or $mode =~ NotUndef or $label =~ NotUndef {
    file { '/etc/garrett':
      ensure => directory,
      owner  => 'root',
      group  => 'root',
      mode   => '0755',
    }
    file { '/etc/garrett/garrett.conf':
      ensure    => file,
      owner     => 'root',
      group     => 'root',
      mode      => '0600',
      show_diff => false,
      content   => Sensitive(epp('garrett/garrett.conf.epp', {
        'server'     => $server,
        'enroll_key' => $key,
        'mode'       => $mode,
        'label'      => $label,
      })),
      before    => Package['garrett'],
      notify    => $restart,
    }
  }

  if $family == 'Debian' {
    # The apt repository, as the README adds it.
    file { '/usr/share/keyrings/garrett.gpg':
      ensure         => file,
      owner          => 'root',
      group          => 'root',
      mode           => '0644',
      source         => "${repository}/garrett.gpg",
      checksum       => 'sha256',
      checksum_value => $apt_key_sha256,
    }
    # Nothing goes further unless the key on the machine is the one pinned.
    -> exec { 'garrett: the apt signing key is the one pinned':
      provider    => shell,
      command     => 'echo "/usr/share/keyrings/garrett.gpg is not the key garrett::apt_key_sha256 pins." >&2; exit 1',
      unless      => '[ "$(sha256sum /usr/share/keyrings/garrett.gpg | cut -d" " -f1)" = "$GARRETT_PIN" ]',
      environment => ["GARRETT_PIN=${apt_key_sha256}"],
      path        => $path,
    }
    -> file { '/etc/apt/sources.list.d/garrett.list':
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => "deb [signed-by=/usr/share/keyrings/garrett.gpg] ${repository} stable main\n",
    }
    # Only garrett's list is read, as packaging/install.sh reads it, and only while apt does not know garrett yet.
    -> exec { 'garrett: apt reads the repository':
      provider    => shell,
      command     => 'apt-get update -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/garrett.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0',
      unless      => 'apt-cache policy garrett | grep -q "Candidate: [0-9]"',
      environment => ['LC_ALL=C'],
      path        => $path,
    }
    -> package { 'garrett':
      ensure => installed,
    }
  } else {
    # The rpm repository, as packaging/rpm/garrett.repo defines it. Its list of packages carries the project's
    # signature; the key is imported only if its fingerprint is the project's.
    $import_key = @(SCRIPT)
      set -eu
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      export GNUPGHOME="$work"
      curl -fsSL "$GARRETT_KEY_URL" -o "$work/garrett.asc"
      found=$(gpg --batch --with-colons --show-keys "$work/garrett.asc" | awk -F: '/^fpr/ {print $10; exit}')
      if [ "$found" != "$GARRETT_FINGERPRINT" ]; then
        echo "$GARRETT_KEY_URL holds the key $found, not $GARRETT_FINGERPRINT. Nothing was imported." >&2
        exit 1
      fi
      rpm --import "$work/garrett.asc"
      | SCRIPT
    # rpm names an imported key by its short key id, or from rpm 6 on by its fingerprint.
    $key_imported = @(SCRIPT)
      short=$(printf '%s' "$GARRETT_FINGERPRINT" | cut -c33-40)
      rpm -q gpg-pubkey --qf '%{version}\n' 2>/dev/null | grep -qix -e "$short" -e "$GARRETT_FINGERPRINT"
      | SCRIPT
    $repo_file = $family ? {
      'Suse'  => '/etc/zypp/repos.d/garrett.repo',
      default => '/etc/yum.repos.d/garrett.repo',
    }

    exec { 'garrett: import the signing key, checked against its fingerprint':
      provider    => shell,
      command     => $import_key,
      unless      => $key_imported,
      environment => ["GARRETT_KEY_URL=${repository}/garrett.asc", "GARRETT_FINGERPRINT=${key_fingerprint}"],
      path        => $path,
    }
    -> file { $repo_file:
      ensure  => file,
      owner   => 'root',
      group   => 'root',
      mode    => '0644',
      content => epp('garrett/garrett.repo.epp', { 'repository' => $repository }),
    }
    -> package { 'garrett':
      ensure => installed,
    }

    # The key the repository names is the one checked against its fingerprint above: zypper may take it.
    if $family == 'Suse' {
      exec { 'garrett: zypper reads the repository':
        provider    => shell,
        command     => 'zypper --non-interactive --gpg-auto-import-keys refresh garrett',
        refreshonly => true,
        path        => $path,
        subscribe   => File[$repo_file],
        before      => Package['garrett'],
      }
    }
  }

  # Like most packages with a service on Fedora, RHEL and openSUSE, the rpm package does not start garrett itself.
  if $manage_service {
    service { 'garrett':
      ensure  => running,
      enable  => true,
      require => Package['garrett'],
    }
  }
}
