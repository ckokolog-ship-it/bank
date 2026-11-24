"""test_k8s.py -- the files of the cluster k3s (k8s/): bank.yaml read as YAML (its kinds, its placeholders, the
replicas, the rolling update that keeps 2 ready, the probes: ready by /api/health, alive by the port only, the
sticky cookie of the ATM, no password in it), the Dockerfile (a user not root, the jar), the shell scripts (bash -n).
No cluster, no database: it runs everywhere.

    python3 -m pytest -q tests/test_k8s.py
"""
import os
import subprocess

import pytest

yaml = pytest.importorskip('yaml')
K8S = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'k8s')


def docs():
    with open(os.path.join(K8S, 'bank.yaml'), encoding='utf-8') as f:
        return {d['kind']: d for d in yaml.safe_load_all(f) if d}


def test_the_objects_of_the_bank():
    d = docs()
    assert set(d) == {'Namespace', 'ConfigMap', 'Deployment', 'Service', 'Ingress', 'PodDisruptionBudget',
                      'HorizontalPodAutoscaler'}
    assert all(x['metadata'].get('namespace', 'bank') == 'bank' for x in d.values())
    text = open(os.path.join(K8S, 'bank.yaml'), encoding='utf-8').read()
    assert '@IMAGE@' in text and '@DB_URL@' in text
    # no password in it: no Secret, none in the ConfigMap (the Secret bk-db: made by deploy.sh, asked)
    assert 'Secret' not in d and not [k for k in d['ConfigMap']['data'] if 'PASSWORD' in k]


def test_the_deployment():
    dep = docs()['Deployment']['spec']
    assert dep['replicas'] == 2
    assert dep['strategy']['rollingUpdate'] == {'maxUnavailable': 0, 'maxSurge': 1}
    c = dep['template']['spec']['containers'][0]
    assert c['image'] == '@IMAGE@' and c['imagePullPolicy'] == 'IfNotPresent'
    assert c['readinessProbe']['httpGet']['path'] == '/api/health'
    assert 'tcpSocket' in c['livenessProbe'] and 'httpGet' not in c['livenessProbe']
    assert {e.get('secretRef', {}).get('name') for e in c['envFrom']} >= {'bk-db'}
    assert c['securityContext']['capabilities']['drop'] == ['ALL']
    assert dep['template']['spec']['securityContext']['runAsNonRoot'] is True
    assert docs()['ConfigMap']['data']['BK_DB_URL'] == '@DB_URL@'


def test_the_service_and_the_rest():
    d = docs()
    ann = d['Service']['metadata']['annotations']
    assert ann['traefik.ingress.kubernetes.io/service.sticky.cookie'] == 'true'
    assert d['PodDisruptionBudget']['spec']['minAvailable'] == 1
    hpa = d['HorizontalPodAutoscaler']['spec']
    assert (hpa['minReplicas'], hpa['maxReplicas']) == (2, 4)
    assert d['Ingress']['spec']['rules'][0]['http']['paths'][0]['backend']['service']['name'] == 'bk-api'


def test_the_dockerfile():
    t = open(os.path.join(K8S, 'Dockerfile'), encoding='utf-8').read()
    assert 'USER 10001' in t and 'COPY api/target/bk-api.jar' in t and 'BK_API_BIND=0.0.0.0' in t
    assert not [line for line in t.splitlines() if line.startswith('ENV') and 'PASSWORD' in line.upper()]


@pytest.mark.parametrize('name', ['node.sh', 'ship_image.sh', 'deploy.sh'])
def test_the_scripts(name):
    subprocess.run(['bash', '-n', os.path.join(K8S, name)], check=True)
