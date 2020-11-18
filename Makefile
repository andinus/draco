# Install to /usr/local unless otherwise specified, such as `make
# PREFIX=/app`.
PREFIX?=/usr/local

INSTALL?=install
INSTALL_PROGRAM=$(INSTALL) -Dm 755
INSTALL_DATA=$(INSTALL) -Dm 644

bindir=$(DESTDIR)$(PREFIX)/bin
sharedir=$(DESTDIR)$(PREFIX)/share

# OpenBSD doesn't index /usr/local/share/man by default so
# /usr/local/man will be used.
platform_id != uname -s
mandir != if [ $(platform_id) = OpenBSD ]; then \
    echo $(DESTDIR)$(PREFIX)/man; \
else \
    echo $(DESTDIR)$(PREFIX)/share/man; \
fi

help:
	@echo "targets:"
	@awk -F '#' '/^[a-zA-Z0-9_-]+:.*?#/ { print $0 }' $(MAKEFILE_LIST) \
	| sed -n 's/^\(.*\): \(.*\)#\(.*\)/  \1|-\3/p' \
	| column -t  -s '|'

install: draco.pl draco.1 README.org # system install
	$(INSTALL_PROGRAM) draco.pl $(bindir)/draco

	$(INSTALL_DATA) draco.1 $(mandir)/man1/draco.1
	$(INSTALL_DATA) README.org $(sharedir)/doc/draco/README.org


uninstall: # system uninstall
	rm -f $(bindir)/draco
	rm -f $(mandir)/man1/draco.1
	rm -fr $(sharedir)/doc/draco/

.PHONY: install uninstall help
