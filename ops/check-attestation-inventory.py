#!/usr/bin/env python3
"""Collect and validate the non-secret, role-specific production inventory."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SHA256_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
WILDCARD_ADDRESSES = {"0.0.0.0", "::", "*"}
SENSITIVE_PORTS = {3000, 8000, 8081, 9090, 3100, 13100, 19090, 27017, 8888}

ALLOY_REFERENCE = (
    "grafana/alloy:v1.18.1@"
    "sha256:0f4434c92b3e6cdac38bb129b344e1790c246f7b6e2eaffcc16a5fa363240e33"
)
ALLOY_DIGEST = (
    "grafana/alloy@"
    "sha256:0f4434c92b3e6cdac38bb129b344e1790c246f7b6e2eaffcc16a5fa363240e33"
)


@dataclass(frozen=True)
class ContainerRequirement:
    selector_kind: str
    selector_value: str
    expected_key: str
    configured_image: str | None = None
    repo_digest: str | None = None
    require_expected_id: bool = False


PINNED_MONITORING_CONTAINERS = (
    ContainerRequirement(
        "name",
        "telescan_grafana",
        "telescan_grafana",
        "grafana/grafana:13.2.0@sha256:3fd54ae1214669f8355f065ec9f6445d5279a3d77095ab048ca045685272429b",
        "grafana/grafana@sha256:3fd54ae1214669f8355f065ec9f6445d5279a3d77095ab048ca045685272429b",
    ),
    ContainerRequirement(
        "name",
        "telescan_prometheus",
        "telescan_prometheus",
        "prom/prometheus:v3.14.0@sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0",
        "prom/prometheus@sha256:5ce7540c3c00ef4ab0c9d2c995c6a5b9c421f44b4a115d97a2c7af3b1c21cbb0",
    ),
    ContainerRequirement(
        "name",
        "telescan_loki",
        "telescan_loki",
        "grafana/loki:3.7.6@sha256:efd47c67f9bac88ca29bcf8cb997d9ab29d1848bd0aff579282295542a745952",
        "grafana/loki@sha256:efd47c67f9bac88ca29bcf8cb997d9ab29d1848bd0aff579282295542a745952",
    ),
    ContainerRequirement(
        "name", "telescan_alloy", "telescan_alloy", ALLOY_REFERENCE, ALLOY_DIGEST
    ),
    ContainerRequirement(
        "name",
        "telescan_restricted_ingest",
        "telescan_restricted_ingest",
        "nginx:1.30.4-alpine3.24@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46",
        "nginx@sha256:97d490c12ba55b4946b01546d1c3ed324e8d41ab1c9fcb2a616aa470620e5b46",
    ),
)

ROLE_CONTAINERS = {
    "monitoring": PINNED_MONITORING_CONTAINERS,
    "moscow": (
        ContainerRequirement(
            "name",
            "telescan-nginx",
            "telescan-nginx",
            "telescan-nginx:release",
            require_expected_id=True,
        ),
        ContainerRequirement(
            "name", "telescan_api", "telescan_api", require_expected_id=True
        ),
        ContainerRequirement(
            "name", "mongo_db", "mongo_db", "mongo:8.0", require_expected_id=True
        ),
        ContainerRequirement(
            "name",
            "telescan_admin_bot",
            "telescan_admin_bot",
            require_expected_id=True,
        ),
        ContainerRequirement(
            "service",
            "telescan-bot-app",
            "service/telescan-bot-app",
            require_expected_id=True,
        ),
        ContainerRequirement(
            "name",
            "telescan_alloy_agent",
            "telescan_alloy_agent",
            ALLOY_REFERENCE,
            ALLOY_DIGEST,
        ),
    ),
    "eu": (
        ContainerRequirement(
            "name",
            "telescan_relay",
            "telescan_relay",
            "telescan-relay:release",
            require_expected_id=True,
        ),
        ContainerRequirement(
            "name",
            "telescan_alloy_agent",
            "telescan_alloy_agent",
            ALLOY_REFERENCE,
            ALLOY_DIGEST,
        ),
    ),
}

ROLE_LISTENERS = {
    "monitoring": (
        ("tcp", "wildcard", 22),
        ("tcp", "127.0.0.1", 3000),
        ("tcp", "127.0.0.1", 9090),
        ("tcp", "127.0.0.1", 3100),
        ("tcp", "10.78.0.1", 19090),
        ("tcp", "10.78.0.1", 13100),
        ("udp", "wildcard", 51821),
    ),
    "moscow": (
        ("tcp", "wildcard", 22),
        ("tcp", "wildcard", 80),
        ("tcp", "wildcard", 443),
        ("tcp", "127.0.0.1", 8000),
        ("tcp", "127.0.0.1", 27017),
        ("tcp", "10.77.0.1", 8081),
    ),
    "eu": (
        ("tcp", "wildcard", 22),
        ("tcp", "wildcard", 80),
        ("tcp", "wildcard", 443),
        ("tcp", "10.78.0.3", 8888),
        ("udp", "wildcard", 51820),
    ),
}

ROLE_DOCKER_BINDINGS = {
    "monitoring": {
        ("telescan_grafana", 3000, "tcp", "127.0.0.1", 3000),
        ("telescan_prometheus", 9090, "tcp", "127.0.0.1", 9090),
        ("telescan_loki", 3100, "tcp", "127.0.0.1", 3100),
        ("telescan_restricted_ingest", 19090, "tcp", "10.78.0.1", 19090),
        ("telescan_restricted_ingest", 13100, "tcp", "10.78.0.1", 13100),
    },
    "moscow": {
        ("telescan-nginx", 80, "tcp", "0.0.0.0", 80),
        ("telescan-nginx", 443, "tcp", "0.0.0.0", 443),
        ("telescan-nginx", 8081, "tcp", "10.77.0.1", 8081),
        ("telescan_api", 8000, "tcp", "127.0.0.1", 8000),
        ("mongo_db", 27017, "tcp", "127.0.0.1", 27017),
    },
    "eu": {
        ("telescan_relay", 80, "tcp", "0.0.0.0", 80),
        ("telescan_relay", 443, "tcp", "0.0.0.0", 443),
    },
}


def command(*args: str) -> str:
    result = subprocess.run(args, check=False, text=True, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "no output"
        raise RuntimeError(f"{' '.join(args)} failed: {detail}")
    return result.stdout


def resolve_ipv4(host: str) -> list[str]:
    values: set[str] = set()
    if shutil.which("dig"):
        output = command("dig", "+short", "A", host)
        candidates = output.splitlines()
    else:
        output = command("getent", "ahostsv4", host)
        candidates = [line.split()[0] for line in output.splitlines() if line.split()]
    for candidate in candidates:
        candidate = candidate.strip()
        try:
            address = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if address.version == 4:
            values.add(str(address))
    return sorted(values)


def split_socket(value: str) -> tuple[str, int]:
    value = value.strip()
    if value.startswith("[") and "]:" in value:
        address, port_text = value[1:].rsplit("]:", 1)
    else:
        address, port_text = value.rsplit(":", 1)
    address = address.split("%", 1)[0]
    return address, int(port_text)


def live_listeners() -> tuple[list[dict[str, Any]], str]:
    output = command("ss", "-H", "-lntu")
    listeners: list[dict[str, Any]] = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) < 5:
            raise RuntimeError(f"unparseable ss row: {line}")
        protocol = fields[0].lower()
        address, port = split_socket(fields[4])
        listeners.append({"protocol": protocol, "address": address, "port": port})
    return listeners, output


def live_containers() -> list[dict[str, Any]]:
    names = [name for name in command("docker", "ps", "--format", "{{.Names}}").splitlines() if name]
    containers: list[dict[str, Any]] = []
    for name in names:
        output = command(
            "docker",
            "inspect",
            "--format",
            '{{json .Name}}\t{{json .State.Running}}\t{{json .Image}}\t{{json .Config.Image}}\t{{json (index .Config.Labels "com.docker.compose.service")}}\t{{json .HostConfig.PortBindings}}',
            name,
        ).strip()
        fields = output.split("\t")
        if len(fields) != 6:
            raise RuntimeError(f"unparseable docker inspect row for {name}")
        raw_name, running, image_id, configured_image, service, raw_port_bindings = map(
            json.loads, fields
        )
        port_bindings = []
        for container_port, bindings in (raw_port_bindings or {}).items():
            for binding in bindings or []:
                port_bindings.append(
                    {
                        "container_port": container_port,
                        "host_ip": binding.get("HostIp", ""),
                        "host_port": binding.get("HostPort", ""),
                    }
                )
        image_output = command(
            "docker",
            "image",
            "inspect",
            "--format",
            "{{json .RepoDigests}}",
            image_id,
        ).strip()
        repo_digests = json.loads(image_output)
        containers.append(
            {
                "name": raw_name.lstrip("/"),
                "service": service or "",
                "running": bool(running),
                "image_id": image_id,
                "configured_image": configured_image,
                "repo_digests": repo_digests or [],
                "port_bindings": port_bindings,
            }
        )
    return containers


def collect_live_state() -> tuple[dict[str, Any], str]:
    listeners, listener_output = live_listeners()
    state = {
        "dns": {
            "api.tgtelescan.ru": resolve_ipv4("api.tgtelescan.ru"),
            "tgtelescan.ru": resolve_ipv4("tgtelescan.ru"),
        },
        "listeners": listeners,
        "containers": live_containers(),
    }
    return state, listener_output


def parse_expected_ids(values: list[str]) -> tuple[dict[str, str], list[str]]:
    expected: dict[str, str] = {}
    failures: list[str] = []
    for value in values:
        if "=" not in value:
            failures.append(f"invalid expected image identity: {value}")
            continue
        key, image_id = value.split("=", 1)
        if not key or not SHA256_ID.fullmatch(image_id):
            failures.append(f"invalid expected image identity: {value}")
            continue
        if key in expected:
            failures.append(f"duplicate expected image identity: {key}")
            continue
        expected[key] = image_id
    return expected, failures


def listener_present(listeners: list[dict[str, Any]], requirement: tuple[str, str, int]) -> bool:
    protocol, address, port = requirement
    for listener in listeners:
        if listener.get("protocol") != protocol or listener.get("port") != port:
            continue
        actual_address = listener.get("address")
        if address == "wildcard" and actual_address in WILDCARD_ADDRESSES:
            return True
        if actual_address == address:
            return True
    return False


def socket_allowed(role: str, protocol: str, address: str, port: int) -> bool:
    for expected_protocol, expected_address, expected_port in ROLE_LISTENERS[role]:
        if protocol != expected_protocol or port != expected_port:
            continue
        if expected_address == "wildcard":
            return address in WILDCARD_ADDRESSES
        if address == expected_address:
            return True
    return False


def loopback_address(address: str) -> bool:
    try:
        return ipaddress.ip_address(address.split("%", 1)[0]).is_loopback
    except ValueError:
        return False


def validate_container_bindings(
    containers: list[dict[str, Any]], role: str
) -> list[str]:
    failures: list[str] = []
    actual_bindings: set[tuple[str, int, str, str, int]] = set()
    for container in containers:
        if not isinstance(container, dict):
            failures.append(f"invalid container inventory entry: {container}")
            continue
        identity = f"container={container.get('name', 'unknown')}"
        port_bindings = container.get("port_bindings")
        if not isinstance(port_bindings, list):
            failures.append(f"Docker port bindings are unavailable: {identity}")
            continue
        for binding in port_bindings:
            if not isinstance(binding, dict):
                failures.append(f"invalid Docker port binding for {identity}: {binding}")
                continue
            container_port = binding.get("container_port")
            if not isinstance(container_port, str) or not re.fullmatch(
                r"[0-9]+/(tcp|udp)", container_port
            ):
                failures.append(f"invalid Docker port binding for {identity}: {binding}")
                continue
            container_port_text, protocol = container_port.rsplit("/", 1)
            container_port_number = int(container_port_text)
            try:
                host_port = int(binding.get("host_port"))
            except (TypeError, ValueError):
                failures.append(f"invalid Docker port binding for {identity}: {binding}")
                continue
            host_ip = binding.get("host_ip") or "0.0.0.0"
            if (
                not isinstance(host_ip, str)
                or not 1 <= container_port_number <= 65535
                or not 1 <= host_port <= 65535
            ):
                failures.append(f"invalid Docker port binding for {identity}: {binding}")
                continue
            binding_identity = (
                str(container.get("name", "")),
                container_port_number,
                protocol,
                host_ip,
                host_port,
            )
            actual_bindings.add(binding_identity)
            if binding_identity not in ROLE_DOCKER_BINDINGS[role]:
                failures.append(
                    f"Docker port binding is outside the exact {role} allowlist for "
                    f"{identity}: container={container_port_number}/{protocol} "
                    f"host={host_ip}:{host_port}"
                )
    missing_bindings = sorted(ROLE_DOCKER_BINDINGS[role] - actual_bindings)
    if missing_bindings:
        failures.append(f"required Docker port bindings are missing: {missing_bindings}")
    return failures


def select_containers(
    containers: list[dict[str, Any]], requirement: ContainerRequirement
) -> list[dict[str, Any]]:
    return [
        container
        for container in containers
        if container.get(requirement.selector_kind) == requirement.selector_value
    ]


def validate_exact_container_inventory(
    containers: list[dict[str, Any]], role: str
) -> list[str]:
    failures: list[str] = []
    requirements = ROLE_CONTAINERS[role]
    for container in containers:
        if not isinstance(container, dict):
            continue
        matches = [
            requirement
            for requirement in requirements
            if container.get(requirement.selector_kind) == requirement.selector_value
        ]
        if len(matches) != 1:
            failures.append(
                "unexpected running container outside the exact "
                f"{role} inventory: name={container.get('name')} "
                f"service={container.get('service')} matches={len(matches)}"
            )
    return failures


def validate_state(
    state: dict[str, Any],
    role: str,
    expected_api_ip: str,
    expected_main_ip: str,
    expected_ids: dict[str, str],
) -> list[str]:
    failures: list[str] = []
    dns = state.get("dns")
    listeners = state.get("listeners")
    containers = state.get("containers")
    if not isinstance(dns, dict) or not isinstance(listeners, list) or not isinstance(containers, list):
        return ["inventory must contain dns, listeners, and containers"]

    expected_dns = {
        "api.tgtelescan.ru": [expected_api_ip],
        "tgtelescan.ru": [expected_main_ip],
    }
    for host, expected_values in expected_dns.items():
        values = dns.get(host)
        if not isinstance(values, list) or sorted(set(values)) != expected_values:
            failures.append(
                f"DNS mismatch for {host}: expected={expected_values} actual={values}"
            )

    for requirement in ROLE_LISTENERS[role]:
        if not listener_present(listeners, requirement):
            failures.append(
                "missing required listener: "
                f"role={role} protocol={requirement[0]} address={requirement[1]} port={requirement[2]}"
            )

    for listener in listeners:
        if not isinstance(listener, dict):
            failures.append(f"invalid listener inventory entry: {listener}")
            continue
        protocol = listener.get("protocol")
        address = listener.get("address")
        port = listener.get("port")
        if (
            not isinstance(protocol, str)
            or not isinstance(address, str)
            or not isinstance(port, int)
            or not 1 <= port <= 65535
        ):
            failures.append(f"invalid listener inventory entry: {listener}")
            continue
        allowed = socket_allowed(role, protocol, address, port)
        if port in SENSITIVE_PORTS and not allowed:
            failures.append(
                f"sensitive listener is outside the {role} allowlist: "
                f"{protocol} {address}:{port}"
            )
        elif not loopback_address(address) and not allowed:
            failures.append(
                f"non-loopback listener is outside the exact {role} allowlist: "
                f"{protocol} {address}:{port}"
            )

    # Docker can publish a port without a userland-proxy listener visible to
    # ss. Validate bindings from every running container, including containers
    # outside the required inventory, against the same role socket allowlist.
    failures.extend(validate_container_bindings(containers, role))
    # A second unbound API process is still security-relevant: it can join the
    # Docker network and bypass the single-process mutation lock assumptions.
    # Freeze the complete running-container inventory, not only port owners.
    failures.extend(validate_exact_container_inventory(containers, role))

    required_expected_keys = {
        requirement.expected_key
        for requirement in ROLE_CONTAINERS[role]
        if requirement.require_expected_id
    }
    missing_expected_keys = sorted(required_expected_keys - expected_ids.keys())
    extra_expected_keys = sorted(expected_ids.keys() - required_expected_keys)
    if missing_expected_keys:
        failures.append(f"missing expected image identities: {missing_expected_keys}")
    if extra_expected_keys:
        failures.append(f"unexpected image identities for role {role}: {extra_expected_keys}")

    for requirement in ROLE_CONTAINERS[role]:
        matches = select_containers(containers, requirement)
        selector = f"{requirement.selector_kind}={requirement.selector_value}"
        if len(matches) != 1:
            failures.append(
                f"required container cardinality mismatch: {selector} expected=1 actual={len(matches)}"
            )
            continue
        container = matches[0]
        if container.get("running") is not True:
            failures.append(f"required container is not running: {selector}")
        image_id = container.get("image_id")
        if not isinstance(image_id, str) or not SHA256_ID.fullmatch(image_id):
            failures.append(f"required container image ID is missing or invalid: {selector}")
        expected_id = expected_ids.get(requirement.expected_key)
        if requirement.require_expected_id and image_id != expected_id:
            failures.append(
                f"image identity mismatch for {selector}: expected={expected_id} actual={image_id}"
            )
        configured_image = container.get("configured_image")
        if not isinstance(configured_image, str) or not configured_image:
            failures.append(f"configured image reference is missing: {selector}")
        elif requirement.configured_image and configured_image != requirement.configured_image:
            failures.append(
                f"configured image mismatch for {selector}: "
                f"expected={requirement.configured_image} actual={configured_image}"
            )
        repo_digests = container.get("repo_digests")
        if not isinstance(repo_digests, list):
            failures.append(f"repository digests are unavailable: {selector}")
        elif requirement.repo_digest and requirement.repo_digest not in repo_digests:
            failures.append(
                f"pinned repository digest mismatch for {selector}: "
                f"expected={requirement.repo_digest} actual={repo_digests}"
            )
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--role", required=True, choices=sorted(ROLE_CONTAINERS))
    parser.add_argument("--expected-api-ip", required=True)
    parser.add_argument("--expected-main-ip", required=True)
    parser.add_argument("--expected-image-id", action="append", default=[])
    parser.add_argument("--fixture", type=Path)
    args = parser.parse_args()

    for value in (args.expected_api_ip, args.expected_main_ip):
        try:
            if ipaddress.ip_address(value).version != 4:
                raise ValueError
        except ValueError:
            parser.error("expected DNS values must be IPv4 addresses")

    expected_ids, failures = parse_expected_ids(args.expected_image_id)
    listener_output = ""
    if args.fixture:
        if os.environ.get("TELESCAN_ATTESTATION_TEST_MODE") != "1":
            parser.error("--fixture is restricted to TELESCAN_ATTESTATION_TEST_MODE=1")
        with args.fixture.open(encoding="utf-8") as fixture_file:
            state = json.load(fixture_file)
    else:
        try:
            state, listener_output = collect_live_state()
        except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
            print(f"inventory collection failed: {error}", file=sys.stderr)
            return 1

    failures.extend(
        validate_state(
            state,
            args.role,
            args.expected_api_ip,
            args.expected_main_ip,
            expected_ids,
        )
    )

    print("### exact DNS")
    for host in ("api.tgtelescan.ru", "tgtelescan.ru"):
        print(f"{host} A={json.dumps(state.get('dns', {}).get(host), sort_keys=True)}")
    print("### required listeners")
    for listener in state.get("listeners", []):
        print(
            f"protocol={listener.get('protocol')} address={listener.get('address')} "
            f"port={listener.get('port')}"
        )
    if listener_output:
        print("### raw ss evidence")
        print(listener_output.rstrip())
    print("### required containers and immutable image evidence")
    for container in state.get("containers", []):
        print(
            f"container={container.get('name')} service={container.get('service')} "
            f"running={container.get('running')} configured_image={container.get('configured_image')} "
            f"image_id={container.get('image_id')} "
            f"repo_digests={json.dumps(container.get('repo_digests'), sort_keys=True)} "
            f"port_bindings={json.dumps(container.get('port_bindings'), sort_keys=True)}"
        )

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1
    print(f"role_inventory=passed role={args.role}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
