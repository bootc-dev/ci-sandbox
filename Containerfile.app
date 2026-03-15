# Containerfile.app — Minimal httpd application container
#
# This is a plain OCI container image, not a bootc image.
# Sealing happens AFTER build via cfsctl (see Justfile seal-app target).

FROM quay.io/centos/centos:stream10

RUN dnf install -y httpd && dnf clean all

RUN cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>Sealed composefs demo</title></head>
<body>
<h1>Hello from a sealed container</h1>
<p>This container's filesystem is verified by composefs fs-verity signatures.</p>
</body>
</html>
HTML

EXPOSE 80
CMD ["/usr/sbin/httpd", "-DFOREGROUND"]
