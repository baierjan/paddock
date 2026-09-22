#
# spec file for package paddock
#
# Copyright (c) 2026 Jan Baier
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via https://bugs.opensuse.org/
#


Name:           paddock
Version:        0
Release:        0
Summary:        Hardened krun/microVM-backed Podman sandboxes for AI coding CLIs
License:        Apache-2.0
URL:            https://github.com/baierjan/paddock
Source:         %{name}-%{version}.tar.gz
# For %%check: test_paddock.sh mocks podman but still needs the real
# shellcheck for the lint gate.
BuildRequires:  ShellCheck
Requires:       %{_bindir}/krun
Requires:       %{_bindir}/pasta
Requires:       %{_bindir}/podman
BuildArch:      noarch

%description
Paddock is a secure, lightweight, project-specific sandboxed runtime
container environment for running AI coding assistants (such as OpenCode
and the Gemini CLI) in complete, virtualized isolation from the host.

It uses a pure Containerfile layering strategy and a pristine home
directory strategy to provide transparent, standard host bind-mounting
under a hardened, VM-level (krun/libkrun) virtualization boundary: all
capabilities dropped, no new privileges, a read-only root filesystem, a
noexec/nosuid/nodev tmpfs for /tmp, pasta network isolation, and capped
guest RAM/vCPU/PID limits.

%prep
%autosetup

%build

%install
install -Dm 0755 paddock.sh %{buildroot}%{_datadir}/%{name}/paddock.sh
install -Dm 0644 profile/Containerfile %{buildroot}%{_datadir}/%{name}/profile/Containerfile
install -Dm 0755 profile/entrypoint.sh %{buildroot}%{_datadir}/%{name}/profile/entrypoint.sh

cat > %{name}-wrapper <<'EOF'
#!/bin/sh
exec %{_datadir}/%{name}/paddock.sh "$@"
EOF
install -Dm 0755 %{name}-wrapper %{buildroot}%{_bindir}/%{name}

%check
./test_paddock.sh

%files
%license LICENSE
%doc README.md
%{_bindir}/%{name}
%{_datadir}/%{name}/

%changelog
