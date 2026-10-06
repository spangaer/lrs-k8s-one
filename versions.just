# pinned versions and checksums, imported by the justfile
# k3s and kubectl must stay on the same Kubernetes minor

# Debian 13 genericcloud image, see https://cloud.debian.org/images/cloud/trixie/
debian_image_rev := "20261001-2618"
debian_image_file := "debian-13-genericcloud-amd64-" + debian_image_rev + ".qcow2"
debian_image_url := "https://cloud.debian.org/images/cloud/trixie/" + debian_image_rev + "/" \
    + debian_image_file
debian_image_sha512 := "f46f0671a6e5bdec5291ab8972bae2f10e5408c2f64a74078f11efc2f06a436a" \
    + "9d0313ed50e0472542eeabf780e9f7c792ac0a314c6c20507fcd9fd81b468c3d"

# k3s release, see https://github.com/k3s-io/k3s/releases
k3s_version := "v1.36.5+k3s1"
k3s_url := "https://github.com/k3s-io/k3s/releases/download/" \
    + replace(k3s_version, "+", "%2B")
k3s_sha256 := "d73847bcd3c5fccef0115b372e2f9a91f3032dc84bbf71518a4617565294d313"
k3s_images_file := "k3s-airgap-images-amd64.tar.zst"
k3s_images_sha256 := "7d939471907df2d4e537a9c308bf94173e453fff4a2e9e77e9ae92a64be3007f"

# install.sh at the commit tagged k3s_version
k3s_install_rev := "3dd98cc58ec34991e7e59b93663eee2e26fc1f65"
k3s_install_url := "https://raw.githubusercontent.com/k3s-io/k3s/" + k3s_install_rev \
    + "/install.sh"
k3s_install_sha256 := "46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad"

# Debian's kubectl (1.32) doesn't match k3s, so use the upstream binary
kubectl_version := "v1.36.5"
kubectl_url := "https://dl.k8s.io/release/" + kubectl_version + "/bin/linux/amd64/kubectl"
kubectl_sha256 := "33bc88a24c3b09cf55bfd59e6ca977881b61fc3f25ab65bc80c65b430248648e"
