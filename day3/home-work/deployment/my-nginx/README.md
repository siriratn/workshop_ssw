
# Deployment image nginx 
##  สร้าง Declarative YAML via Imperative Command
```
kubectl create deploy nginx \
  --image=nginx:1.25-alpine \
  --replicas=12 \
  --dry-run=client -o yaml > nginx-deploy.yaml

```


## Apply v1
kubectl apply -f nginx-deploy.yaml

# ตรวจสอบ
kubectl get deploy,rs,pod
kubectl rollout history deploy nginx


## Update Deploy version ใหม่ nginx:1.27-alpine
kubectl set image deploy nginx nginx=nginx:1.27-alpine


## ดู rollout progress
kubectl rollout status deploy nginx -w

## ตรวจสอบ v2
kubectl describe deploy nginx | grep Image
kubectl rollout history deploy nginx

## Rollback (ถ้าจำเป็น)
kubectl rollout undo deploy nginx
kubectl rollout undo deploy nginx --to-revision=1

## คำสั่งอื่น ๆ
Kubectl get deploy ,rs,po 
Kubectl get pod -w