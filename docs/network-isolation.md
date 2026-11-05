# Aislamiento de la red: qué está realmente aislado y qué no

Documento de referencia del ítem **"la base de datos en una subnet privada"** del
checklist de seguridad del capstone.

Fecha de la verificación: 2026-11-05
Cuenta: `607856468834` (us-east-1)
Infraestructura: EC2 `i-0d3f04316b63ee928` (t3.small, Amazon Linux 2023) + k3s

---

## 1. Resumen en una línea

La base de datos **no está en una subnet privada**: la instancia de k3s que la
corre es la misma que sirve la API pública, así que comparte su IP pública. Lo
que **sí** se cumple es que el puerto de Postgres **no es alcanzable desde
Internet**: el security group solo abre 80 y 443, y el servicio de Kubernetes
es `ClusterIP`, nunca `NodePort` ni `LoadBalancer`.

Es una desviación del enunciado, no un descuido, y está documentada aquí con
su evidencia y su causa raíz.

---

## 2. La desviación, en detalle

### Qué pide el ítem del checklist

Que la base de datos esté en una subnet **sin ruta a Internet**, de modo que
un acceso directo a ella sea imposible por red, y no solo por configuración de
puertos.

### Qué hay desplegado

La VPC tiene **una sola subnet**, pública:

```bash
aws ec2 describe-subnets \
  --filters "Name=tag:Name,Values=journal-api-subnet" \
  --query 'Subnets[0].{Id:SubnetId,Cidr:CidrBlock,Public:MapPublicIpOnLaunch}' \
  --output json
```

```json
{
  "Id": "subnet-0cbf50faf7a62f88f",
  "Cidr": "10.0.1.0/24",
  "Public": true
}
```

Su route table manda `0.0.0.0/0` al Internet Gateway:

```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=journal-api-rt" \
  --query 'RouteTables[0].Routes' --output json
```

```json
[
  { "DestinationCidrBlock": "10.0.0.0/16", "GatewayId": "local",    "State": "active" },
  { "DestinationCidrBlock": "0.0.0.0/0",  "GatewayId": "igw-01144638cb664d0d0", "State": "active" }
]
```

Como la instancia es el **único nodo** del cluster de k3s, en esa subnet viven
a la vez el Postgres, la API, Caddy, el collector de ADOT y Fluent Bit. La
subnet "privada" que haría falta no existe, y **no se puede crear sin
reestructurar el despliegue**: el nodo que tiene que ser privado es
justamente el que atiende el tráfico público.

### La causa raíz

El diseño del capstone es **una sola instancia** que hace de nodo de k3s y de
origen de la API. Partirlo en dos (una instancia pública con Caddy, otra
privada con Postgres) cambiaría la arquitectura completa: dos EIPs, dos
security groups, una subnet privada con su route table sin ruta por defecto,
NAT para que el nodo privado alcance ECR y Secrets Manager, y el secreto de
la base de datos movido a la instancia privada.

Eso es un proyecto, no una corrección de una línea. La decisión de este
capstone es: **una instancia, y el aislamiento del puerto 5432; se documenta
la desviación**.

---

## 3. La evidencia de que el aislamiento real sí se cumple

### 3.1 El security group solo abre 80 y 443

```bash
aws ec2 describe-security-groups --filters "Name=group-name,Values=journal-sg" \
  --query 'SecurityGroups[0].{Id:GroupId,Ingress:IpPermissions}' --output json
```

```
Ingress:
  tcp 80  -> 0.0.0.0/0   (HTTP: ACME + redirect a HTTPS)
  tcp 443 -> 0.0.0.0/0   (HTTPS: API publica)
```

**No hay ninguna regla de ingress para 5432.** El puerto de la base de datos no
está abierto en el grupo de seguridad: no hay forma de que un paquete TCP
llegue al Postgres desde Internet, porque el firewall de la VPC lo descarta
antes de que llegue a la interfaz.

Esto no es accidental: el security group se define en `terraform/main.tf` y en
el puerto 22 está deliberadamente ausente (la administración es por SSM), así
que la ausencia de 5432 es una decisión explícita y auditable en el código.

### 3.2 El puerto 5432 da timeout desde afuera

Probado desde fuera de la VPC, contra la IP pública de la instancia:

```powershell
Test-NetConnection -ComputerName 3.215.52.10 -Port 5432 -WarningAction SilentlyContinue
```

```
TcpTestSucceeded: False
```

Como contraste, el mismo test contra el puerto que sí está abierto:

```powershell
Test-NetConnection -ComputerName 3.215.52.10 -Port 443 -WarningAction SilentlyContinue
```

```
TcpTestSucceeded: True
```

El `timeout` (y no un `refused`) es la firma de un **drop de firewall**: el
paquete sale de la VPC, la SG lo descarta y el cliente se queda esperando la
respuesta hasta que agota el tiempo. Es el comportamiento correcto de un
puerto cerrado.

### 3.3 El servicio de Postgres es `ClusterIP`

```bash
# En la instancia, por SSM:
kubectl -n journal-api get svc postgres -o jsonpath='{.spec.type}'
```

```
ClusterIP
```

`ClusterIP` solo es resoluble dentro del cluster de Kubernetes. No hay
`NodePort` (que publicaría el puerto en la IP del nodo) ni `LoadBalancer` (que
publicaría un ELB de AWS). Aunque el security group lo permitiera, no habría
una IP de entrada.

### 3.4 Postgres no se publica en el nodo

```bash
# En la instancia, por SSM:
kubectl -n journal-api get deploy postgres \
  -o jsonpath='{.spec.template.spec.containers[0].ports}'
```

```json
[{"containerPort":5432,"protocol":"TCP"}]
```

`containerPort` **no** es `hostPort`: el puerto 5432 no se publica en el nodo.
El `containerPort` solo documenta el puerto del contenedor; para que el nodo lo
atendiera haría falta `hostPort: 5432`, que no está.

Dentro del pod, Postgres escucha en todas las interfaces **del pod**:

```
tcp  0  0  0.0.0.0:5432  0.0.0.0:*  LISTEN
tcp  0  0  :::5432       :::*       LISTEN
```

Eso es normal y no es una exposición: el namespace de red del pod es
`10.42.0.0/24` (flannel), una red interna que **no tiene ruta a Internet**. El
tráfico de un pod al exterior sale por el SNAT de la subnet pública.

El detalle que importa es el nodo:

```bash
# En la instancia, por SSM:
sudo ss -lntp | grep -E ':5432|:6443|:80|:443'
```

```
LISTEN 0  4096  *:6443  *:*  users:(("k3s-server",pid=5656,fd=12))
```

El nodo **no** tiene ningún listener en 5432: el puerto de la base de datos no
está abierto en el host, así que no hay nada a lo que conectarse aunque se
conociera la IP. (El `6443` que sí aparece es el API server de k3s, que
escucha en todas las interfaces del nodo; está bloqueado por el security
group, ver §3.1 y §3.6.)

### 3.5 La password nunca está en el pod

```bash
# En la instancia, por SSM:
kubectl -n journal-api exec deploy/postgres -- ls -l /secrets
```

```
-rw------- 1 root root  79 ... DATABASE_URL
-rw------- 1 root root  28 ... POSTGRES_PASSWORD
```

La credencial de la base de datos viene de Secrets Manager y la baja un init
container a un `emptyDir` en memoria. No está en el spec del pod, ni en etcd,
ni en ninguna variable de entorno.

### 3.6 Lo que un atacante necesitaría

Para leer la base de datos desde Internet tendría que:

1. Entrar al cluster de k3s (el API server escucha en `*:6443` del nodo, pero el
   security group no abre ese puerto: verificado desde afuera,
   `TcpTestSucceeded: False`; la administración real es por SSM desde AWS).
2. O compromising el nodo por el único servicio expuesto: HTTPS, que sirve
   una API **sin autenticación** (limitación asumida del capstone, ver
   `README.md` §5).

Es decir: la red no es la barrera, y no pretende serlo. La barrera es que no
existe una ruta de red directa a la base de datos.

---

## 4. Lo que esta desviación deja expuesto (y por qué se acepta)

| Riesgo | ¿Se acepta? | Por qué |
|---|---|---|
| El nodo tiene IP pública | Sí | El nodo sirve la API pública. Separarlo en dos nodos es otro proyecto (§2). |
| Un atacante en el nodo alcanza Postgres por la red de pods | Sí | El aislamiento por red **no** protege contra el compromiso del nodo. Kubernetes ya no es una frontera de seguridad: un pod comprometido ve la red del cluster. |
| El SG es la única barrera de red de Postgres | Sí | Es una barrera real y comprobada (§3.1, §3.2), pero es de perímetro, no de capas. |

**El riesgo residual concreto:** si alguien compromete el nodo (a través de la
API sin autenticación o de otro vector), tiene acceso de red a Postgres sin
necesitar ninguna credencial. En una topología de dos nodos, Postgres en una
subnet sin ruta a Internet seguiría siendo alcanzable **desde el cluster**, y
solo la autenticación de Postgres (que sí está: la password viene de Secrets
Manager) separaría al atacante de los datos.

Por eso la control que de verdad importa aquí no es la subnet: es que la
password de Postgres **nunca está en el pod**. Vive en Secrets Manager y la
baja un init container a un `emptyDir` en memoria:

```bash
# En la instancia, por SSM:
kubectl -n journal-api exec deploy/postgres -- ls -l /secrets
```

```
-rw------- 1 root root  ... POSTGRES_PASSWORD
```

Ese es el control que sobrevive al compromiso del nodo. La subnet privada
sería la segunda capa; esta es la primera.

---

## 5. Cómo se cerraría la desviación

El plan, en orden, para quien retome el proyecto:

1. **Subnet privada** `10.0.2.0/24` con su route table **sin** `0.0.0.0/0` y
   una `aws_nat_gateway` para salida (ECR, Secrets Manager, SSM).
2. **Dos instancias**: `journal-api-public` (Caddy + app) y
   `journal-api-db` (k3s + Postgres). O mejor: **no k3s para la base** —
   `aws_db_instance` (RDS) en la subnet privada, con `storage_encrypted`,
   Multi-AZ y deletion protection.
3. **Security group de la DB**: ingress 5432 **solo** desde el SG de la app,
   nunca `0.0.0.0/0`.
4. **El secreto de la base** pasa a leerse en la instancia privada, o se
   conecta con `iamAuth` en vez de password.

Los pasos 1 y 4 son los que importan. El paso 3 solo formaliza lo que ya hace
el firewall de hoy.

**Nota de costo:** una NAT Gateway cuesta ~$32/mes más los procesamiento de
datos, y RDS instances no entran en el free tier. Ese costo es **la razón
principal** por la que el capstone se queda en una instancia: el proyecto se
mantiene en `$0,00` (ver `docs/security.md` §8) y la topología de dos niveles
con NAT + RDS lo rompe.

---

## 6. Cómo verificar esta desviación en cualquier momento

```bash
# 1. El SG no tiene 5432 (no debe aparecer en la salida)
aws ec2 describe-security-groups --filters "Name=group-name,Values=journal-sg" \
  --query 'SecurityGroups[0].IpPermissions[].{Port:FromPort,Proto:IpProtocol,Cidr:IpRanges[].CidrIp}' \
  --output json

# 2. 5432 no responde desde afuera (esperar timeout)
Test-NetConnection -ComputerName 3.215.52.10 -Port 5432 -WarningAction SilentlyContinue

# 3. El servicio de Postgres es ClusterIP
aws ssm send-command --instance-ids "$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=journal-api-instance" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["kubectl -n journal-api get svc postgres -o jsonpath={.spec.type}"]'
```

Si el primero muestra un 5432, o el segundo dice `TcpTestSucceeded: True`, la
desviación pasó de "documentada" a "corregida" en sentido contrario: el
aislamiento se rompió.

---

## 7. Referencias

- `terraform/main.tf` — VPC, subnet, route table y security group (la subnet
  única y las reglas 80/443).
- `k8s/postgresql.yaml` — Service `ClusterIP` de Postgres, sin `hostPort`.
- `docs/security.md` §7 — limitaciones conocidas del bloque de seguridad.
- `docs/delivery.md` §3 — cómo la password de Postgres llega al pod sin pasar
  por etcd.
- `README.md` §5 — limitaciones de producción asumidas en el capstone.
