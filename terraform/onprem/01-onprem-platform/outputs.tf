output "tunnel_token" {
  value       = module.cloudflared_tunnel.tunnel_token
  description = "EKS에서 복사해 갈 공유 터널 토큰"
  sensitive   = true
}

output "argocd_initial_password_cmd" {
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  description = "초기 admin 비밀번호를 확인하는 명령어입니다."
}

output "argocd_service_status_cmd" {
  value       = "kubectl get svc -n argocd argocd-server"
  description = "ArgoCD 접속 IP(External-IP)를 확인하는 명령어입니다."
}
