
## สร้าง index.html
```
echo "<h1>Hello nid noi</h1>" > index.html
```

## สร้าง ConfigMap YAML via Imperative Command (--from-file)

```
kubectl create cm nginx-cm \
  --from-file=index.html \
  --dry-run=client -o yaml > nginx-cm.yaml

```
### ตรวจสอบไฟล์ที่ได้
cat nginx-cm.yaml

## สร้าง Deployment YAML via Imperative Command

```
kubectl create deploy nginx \
  --image=nginx:1.25-alpine \
  --dry-run=client -o yaml > nginx-deploy.yaml
  ```

### แก้ไข nginx-deploy.yaml เพิ่ม volumeMounts + volumes  

##  สร้าง Service YAML via Imperative Command
```
kubectl expose deploy nginx \
  --port=3000 \
  --target-port=80 \
  --dry-run=client -o yaml > nginx-svc.yaml


```
cat nginx-svc.yaml

## Apply ทั้งหมด

### apply ทีละไฟล์
kubectl apply -f nginx-cm.yaml
kubectl apply -f nginx-deploy.yaml
kubectl apply -f nginx-svc.yaml

### หรือ apply ทั้ง folder พร้อมกัน
kubectl apply -f .

### Port-forward
kubectl port-forward ใช้กับ Pod หรือ Service 

# port-forward ผ่าน Service
kubectl port-forward svc/nginx 3000:3000

# หรือ port-forward ตรงไปที่ Pod
kubectl port-forward pod/<pod-name> 3000:80


 ### ***เมื่อแก้ index.html และ apply ConfigMap ใหม่
 ```
# สร้าง ConfigMapใหม่

kubectl create cm nginx-cm \
  --from-file=index.html \
  --dry-run=client -o yaml > nginx-cm.yaml

# apply
kubectl apply -f nginx-cm.yaml

# 2 ตรวจว่า ConfigMap อัปเดตแล้ว
kubectl describe cm nginx-cm


# 3 Restart Pod เพื่อโหลด ConfigMap ใหม่
# วิธีที่ 1 — rollout restart (แนะนำ)
kubectl rollout restart deploy nginx

 
# 4 ตรวจสอบใน Pod ใหม่
# หา pod name ใหม่
kubectl get pod

# เข้าไปตรวจ
kubectl exec -it <new-pod-name> -- cat /usr/share/nginx/html/index.html

# 5 Port-forward แล้วเปิด browser
kubectl port-forward pod/<pod-name> 3000:80

 ```