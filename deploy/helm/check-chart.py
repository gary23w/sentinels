"""The Helm chart puts on each node the DaemonSet of deploy/kubernetes-daemonset.yaml.

    python3 deploy/helm/check-chart.py MANIFEST VERSION CHART_YAML DEFAULT EXISTING

MANIFEST    deploy/kubernetes-daemonset.yaml
VERSION     the release's version (rust/Cargo.toml's)
CHART_YAML  helm show chart of the chart packaged with --version and --app-version VERSION
DEFAULT     helm template garrett <chart> --namespace garrett
                --set enrolment.server=https://sentinel.example --set enrolment.key=check-key
EXISTING    helm template garrett <chart> --namespace garrett
                --set enrolment.existingSecret=own-enrolment --set mode=report

The rendered DaemonSet's pod spec must be the manifest's, field for field, but for the image: the same host PID and
network namespaces, the same root user with the same four capabilities and no privilege escalation, the same
tolerations, resources, environment, Secret and state folder on the node.
"""
import sys

import yaml

IMAGE = "ghcr.io/gary23w/garrett"
SERVER, KEY = "https://sentinel.example", "check-key"
failures = []


def check(ok, message):
    if not ok:
        failures.append(message)


def differences(want, got, path):
    """Each place where got is not want, as 'path: want ... got ...'."""
    if isinstance(want, dict) and isinstance(got, dict):
        for name in sorted(set(want) | set(got)):
            yield from differences(want.get(name), got.get(name), f"{path}.{name}")
    elif isinstance(want, list) and isinstance(got, list) and len(want) == len(got):
        for index, (one, other) in enumerate(zip(want, got)):
            yield from differences(one, other, f"{path}[{index}]")
    elif want != got:
        yield f"{path}: the manifest has {want!r}, the chart {got!r}"


def objects(path):
    with open(path, encoding="utf-8") as file:
        return [one for one in yaml.safe_load_all(file) if one]


def only(found, kind, where):
    of_kind = [one for one in found if one.get("kind") == kind]
    if len(of_kind) != 1:
        sys.exit(f"{where}: {len(of_kind)} objects of kind {kind}, not one")
    return of_kind[0]


def environment(container):
    return {one["name"]: one for one in container.get("env", [])}


def main(manifest, version, chart_yaml, default, existing):
    # The chart is the release's: its version and the version of the program it puts on the nodes.
    with open(chart_yaml, encoding="utf-8") as file:
        chart = yaml.safe_load(file)
    check(chart.get("name") == "garrett", f"the chart is named {chart.get('name')!r}, not garrett")
    check(str(chart.get("version")) == version, f"the chart's version is {chart.get('version')!r}, not {version}")
    check(str(chart.get("appVersion")) == version, f"the chart's appVersion is {chart.get('appVersion')!r}, not {version}")

    wanted = objects(manifest)
    want = only(wanted, "DaemonSet", manifest)
    want_secret = only(wanted, "Secret", manifest)

    rendered = objects(default)
    got = only(rendered, "DaemonSet", default)
    got_secret = only(rendered, "Secret", default)
    check(sorted(one["kind"] for one in rendered) == ["DaemonSet", "Secret"],
          f"the chart renders {sorted(one['kind'] for one in rendered)}, not a DaemonSet and a Secret")
    for one in rendered:
        check(one["metadata"].get("namespace") == "garrett", f"{one['kind']} is not in the release's namespace")
    check(got["metadata"]["name"] == want["metadata"]["name"],
          f"the DaemonSet is named {got['metadata']['name']!r}, not {want['metadata']['name']!r}")

    # The pod spec, field for field, once the image is set aside: the manifest's is built locally (garrett:latest),
    # the chart's is the release's own on GHCR.
    want_pod, got_pod = want["spec"]["template"]["spec"], got["spec"]["template"]["spec"]
    images = [container.pop("image", None) for container in got_pod.get("containers", [])]
    for container in want_pod["containers"]:
        container.pop("image", None)
    check(images == [f"{IMAGE}:{version}"], f"the chart's image is {images}, not {IMAGE}:{version}")
    for difference in differences(want_pod, got_pod, "spec.template.spec"):
        failures.append(difference)

    # The pods are the DaemonSet's own.
    selector = got["spec"]["selector"]["matchLabels"]
    labels = got["spec"]["template"]["metadata"]["labels"]
    check(selector and all(labels.get(name) == value for name, value in selector.items()),
          "the pod template's labels do not match the DaemonSet's selector")

    # The Secret the nodes enrol with: the manifest's two keys, with what was given.
    check(got_secret["metadata"]["name"] == want_secret["metadata"]["name"],
          f"the Secret is named {got_secret['metadata']['name']!r}, not {want_secret['metadata']['name']!r}")
    check(set(got_secret.get("stringData", {})) == set(want_secret["stringData"]),
          f"the Secret has the keys {sorted(got_secret.get('stringData', {}))}, not {sorted(want_secret['stringData'])}")
    check(got_secret.get("stringData") == {"server": SERVER, "key": KEY}, "the Secret does not hold the given server and key")

    # With a Secret of one's own: the chart makes none, and the nodes enrol with that one, in the mode given.
    rendered = objects(existing)
    check([one["kind"] for one in rendered] == ["DaemonSet"],
          f"with enrolment.existingSecret the chart renders {[one['kind'] for one in rendered]}, not just the DaemonSet")
    env = environment(only(rendered, "DaemonSet", existing)["spec"]["template"]["spec"]["containers"][0])
    for name, key in (("SENTINEL_SERVER", "server"), ("SENTINEL_ENROLL_KEY", "key")):
        reference = env.get(name, {}).get("valueFrom", {}).get("secretKeyRef", {})
        check(reference == {"name": "own-enrolment", "key": key}, f"with enrolment.existingSecret, {name} comes from {reference}")
    check(env.get("SENTINEL_MODE", {}).get("value") == "report", "mode=report does not reach SENTINEL_MODE")

    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        sys.exit(1)
    print(f"The chart {version} puts the manifest's DaemonSet on each node, with the image {IMAGE}:{version}.")


if __name__ == "__main__":
    if len(sys.argv) != 6:
        sys.exit(__doc__)
    main(*sys.argv[1:])
