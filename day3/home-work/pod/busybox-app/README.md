# 1  
## build image

```

docker build -t busybox-app:1.0.0 .

```

### ตรวจสอบ
docker images | grep jumpbox-app

## Imperative Command → Declarative YAML
```
kubectl run busybox-app --image=busybox-app:1.0.0 --port=80 --dry-run=client -o yaml > busybox-app-pod.yaml

<!-- kubectl run busybox-app \        
  --image=busybox-app:1.0.0 \
  --port=80 \
  --dry-run=client -o yaml > busybox-app-pod.yaml -->

```

## Apply และตรวจสอ
### สร้าง Pod
```
kubectl apply -f busybox-app-pod.yaml
```

### ดูสถานะ
kubectl get pod busybox-app

### ดู logs (เช็ค "Hello World") and Monitor
kubectl logs busybox-app
kubectl exec -it busybox-app -- sh