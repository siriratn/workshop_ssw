
#  Deployment image nginx 
##  สร้าง Declarative YAML via Imperative Command
```
kubectl create deploy nginx \
  --image=nginx:1.27-alpine \
  --replicas=2 \
  --dry-run=client -o yaml > nginx-deploy.yaml

```


## Apply
kubectl apply -f nginx-st-deploy.yaml