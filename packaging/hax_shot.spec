%{!?app_version:%global app_version 1.0.0}
%{!?app_release:%global app_release 1}

Name:           hax-shot
Version:        %{app_version}
Release:        %{app_release}%{?dist}
Summary:        Tray-only GNOME Wayland screenshot tool
License:        MIT
URL:            https://github.com/xiehanff/hax_shot
Source0:        hax-shot-bundle.tar.gz
Source1:        hax-shot-icons.tar.gz
Source2:        com.github.xiehanff.hax_shot.desktop
Source3:        install-gnome-shortcut.sh
Source4:        LICENSE
Source5:        README.md
Source6:        THIRD_PARTY_NOTICES.md

BuildArch:      x86_64
BuildRequires:  patchelf

# Flutter ships its own application libraries in the bundle. These are the
# system services and plugins that Hax Shot intentionally does not vendor.
Requires:       gtk3
Requires:       glib2
Requires:       libstdc++
Requires:       keybinder3
Requires:       gstreamer1
Requires:       gstreamer1-plugins-base
Requires:       gstreamer1-plugins-good
Requires:       pipewire
Requires:       pipewire-gstreamer
Requires:       wl-clipboard
Requires:       libayatana-appindicator-gtk3
Recommends:     gnome-shell-extension-appindicator

%description
Hax Shot is a tray-only screenshot tool for Fedora GNOME on Wayland. It uses
Mutter ScreenCast and PipeWire to capture a silent frozen frame, then provides
rectangle selection, PNG saving, and image clipboard support.

%prep

%build

%install
rm -rf %{buildroot}
mkdir -p %{buildroot}/opt/hax-shot
mkdir -p %{buildroot}%{_bindir}
mkdir -p %{buildroot}%{_datadir}/applications
mkdir -p %{buildroot}%{_datadir}/icons
mkdir -p %{buildroot}%{_datadir}/hax-shot

# Keep the complete Flutter bundle together so Dart FFI can resolve the Rust
# cdylib through <executable-dir>/lib/libhax_shot_native.so.
tar -xzf %{SOURCE0} -C %{buildroot}/opt/hax-shot --strip-components=1

# Desktop integration is installed in the standard system locations below;
# remove the copies that Flutter placed inside the relocatable bundle.
rm -rf %{buildroot}/opt/hax-shot/share

tar -xzf %{SOURCE1} -C %{buildroot}%{_datadir}/icons
# index.theme belongs to Fedora's hicolor-icon-theme package; do not claim
# ownership of the shared file in this RPM.
rm -f %{buildroot}%{_datadir}/icons/hicolor/index.theme
sed 's|^Exec=hax_shot$|Exec=/usr/bin/hax_shot|' %{SOURCE2} > \
  %{buildroot}%{_datadir}/applications/com.github.xiehanff.hax_shot.desktop

install -m 0755 %{SOURCE3} \
  %{buildroot}%{_datadir}/hax-shot/install-gnome-shortcut.sh
install -m 0644 %{SOURCE4} %{buildroot}%{_datadir}/hax-shot/LICENSE
install -m 0644 %{SOURCE5} %{buildroot}%{_datadir}/hax-shot/README.md
install -m 0644 %{SOURCE6} \
  %{buildroot}%{_datadir}/hax-shot/THIRD_PARTY_NOTICES.md

# The desktop entry and GNOME shortcut use this stable command. The real
# executable still resolves its bundle directory through /proc/self/exe.
cat > %{buildroot}%{_bindir}/hax_shot <<'EOF'
#!/bin/sh
exec /opt/hax-shot/hax_shot "$@"
EOF
chmod 0755 %{buildroot}%{_bindir}/hax_shot

# Flutter bundles can retain a build-machine RUNPATH. Make every path
# installation-relative before the RPM is assembled.
patchelf --set-rpath '$ORIGIN/lib' %{buildroot}/opt/hax-shot/hax_shot
find %{buildroot}/opt/hax-shot/lib -type f -name '*.so*' \
  -exec patchelf --set-rpath '$ORIGIN' {} +

%post
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor >/dev/null 2>&1 || :
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database %{_datadir}/applications >/dev/null 2>&1 || :
fi

%postun
if [ "$1" -eq 0 ]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor >/dev/null 2>&1 || :
  fi
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database %{_datadir}/applications >/dev/null 2>&1 || :
  fi
fi

%files
%license %{_datadir}/hax-shot/LICENSE
%doc %{_datadir}/hax-shot/README.md
%doc %{_datadir}/hax-shot/THIRD_PARTY_NOTICES.md
/opt/hax-shot
%{_bindir}/hax_shot
%{_datadir}/hax-shot/install-gnome-shortcut.sh
%{_datadir}/applications/com.github.xiehanff.hax_shot.desktop
%{_datadir}/icons/hicolor/*/apps/com.github.xiehanff.hax_shot.png

%changelog
* Sun Sep 06 2026 hax <chinkout@163.com> - 1.0.0-1
- Initial Fedora GNOME Wayland RPM package.
