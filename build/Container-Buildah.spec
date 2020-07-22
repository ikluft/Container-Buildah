Name: <% $zilla->name %>
Version: <% (my $v = $zilla->version) =~ s/^v//; $v %>
Release: 1

Summary: <% $zilla->abstract %>
License: GPL+ or Artistic
Group: Applications/CPAN
BuildArch: noarch
URL: <% $zilla->license->url %>
Source: <% $archive %>

BuildRoot: %{_tmppath}/%{name}-%{version}-BUILD

%description
<% $zilla->abstract %>

%prep
%setup -q

%build
perl Makefile.PL
make test

%install
if [ "%{buildroot}" != "/" ] ; then
	rm -rf %{buildroot}
fi
make pure_install DESTDIR=%{buildroot}
find %{buildroot} | sed -e 's#%{buildroot}##' > %{_tmppath}/filelist

%clean
if [ "%{buildroot}" != "/" ] ; then
	rm -rf %{buildroot}
fi

%files -f %{_tmppath}/filelist
%defattr(-,root,root)
