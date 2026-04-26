

| เรื่อง         | Pod Standalone | Deployment           |
| -------------- | -------------- | -------------------- |
| การสร้าง       | สร้าง Pod ตรงๆ | สร้างผ่าน controller |
| Auto restart   | ❌ ไม่มี        | ✅ มี                 |
| Scaling        | ❌ ไม่ได้       | ✅ replicas           |
| Rolling update | ❌ ไม่ได้       | ✅ ได้                |
| Self-healing   | ❌ ไม่มี        | ✅ pod ตาย recreate   |
| Production     | ❌ ไม่ควรใช้    | ✅ ใช้จริง            |
| Zero downtime  | ❌ ไม่มี        | ✅ มี                 |
| Rollback       | ❌ ไม่มี        | ✅ ได้                |

# 1 Pod Standalone
## สร้าง pod จาก docker image ,Imperative Command → Declarative YAML
```
kubectl run busybox-app \        
  --image=busybox-app:v1.0.0 \
  --port=80 \
  --dry-run=client -o yaml > busybox-app-pod.yaml

# apply
kubectl apply -f busybox-app-pod.yaml
# เช็ค
kubectl get pod
# ถ้า pod ตาย → หายเลย ❌ ไม่มีตัว recreate
kubectl delete pod busybox-app

```

# 2. Deployment คืออะไร
## Deployment = Controller ที่คุม Pod

```
Deployment
   │
ReplicaSet
   │
Pods (หลายตัว)


# Deployment image nginx 
##  สร้าง Declarative YAML via Imperative Command

kubectl create deploy nginx \
  --image=nginx:1.25-alpine \
  --replicas=3 \
  --dry-run=client -o yaml > nginx-deploy.yaml

## apply
kubectl apply -f nginx-deploy.yaml

เช็ค
kubectl get pods

จะได้
nginx-xxxx
nginx-xxxx
nginx-xxxx

# Self Healing (สำคัญ production)

## ลอง delete pod

kubectl delete pod nginx-xxxx

## Deployment จะสร้างใหม่ทันที
nginx-new-xxxx
```

# Scaling

Pod standalone

❌ scale ไม่ได้

## Deployment
kubectl scale deploy nginx --replicas=5

ได้ 5 pods ทันที

# Rolling Update (Production สำคัญมาก)

## Update image
```
 
kubectl set image deployment/nginx-deploy nginx=nginx:1.27-alpine

# Kubernetes จะ
1 สร้าง pod ใหม่
2 ค่อยๆ kill pod เก่า
3 ไม่มี downtime

```
## Rollback

```
kubectl rollout undo deployment nginx-deploy

# ย้อนกลับ version ก่อนทันที
```

==================

# หยุด Deployment ทั้งหมด (Pod หยุดทำงาน แต่ config ยังอยู่)

kubectl scale deploy nginx --replicas=0

# ตรวจสอบ
kubectl get pod
kubectl get all

# ลบทุกอย่าง
## ลบ Deployment nginx (ลบ ReplicaSet + Pod ในนั้นทั้งหมด)
kubectl delete deploy nginx

## ลบ standalone Pods
```
kubectl delete pod nginx-pod --ignore-not-found
kubectl delete pod rust-web-app --ignore-not-found
kubectl delete pod jumpbox --ignore-not-found
kubectl delete pod busybox --ignore-not-found

```