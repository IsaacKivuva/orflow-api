pipeline {

    agent any

    environment {
        APP_NAME          = "orflow-api"
        STAGING_NS        = "orflow-staging"
        PRODUCTION_NS     = "orflow-production"
        STAGING_HOST      = "staging.orflow.local"
        PRODUCTION_HOST   = "api.orflow.local"

        IMAGE_TAG         = "orflow-api:${BUILD_NUMBER}"
        IMAGE_LATEST      = "orflow-api:latest"
    }

    options {
        timeout(time: 30, unit: "MINUTES")
        buildDiscarder(logRotator(numToKeepStr: "10"))
        disableConcurrentBuilds()
        timestamps()
    }

    stages {

        // STAGE 1 — Checkout
        stage("Checkout") {
            steps {
                echo "Checking out source from Git..."
                checkout scm

                script {
                    env.GIT_COMMIT_SHORT = sh(
                        script: "git rev-parse --short HEAD",
                        returnStdout: true
                    ).trim()
                    echo "Build: ${BUILD_NUMBER} | Commit: ${env.GIT_COMMIT_SHORT}"
                }
            }
        }

        // STAGE 2 — Build Docker Image

        stage("Build") {
            steps {
                echo "Building Docker image inside Minikube Docker daemon..."
                script {
                    sh """
                        eval \$(minikube docker-env)
                        docker build \\
                            -t ${IMAGE_TAG} \\
                            -t ${IMAGE_LATEST} \\
                            ./app
                    """
                    echo "Image built: ${IMAGE_TAG}"
                }
            }
        }

        // STAGE 3 — Provision Infrastructure (Terraform)

        stage("Provision") {
            steps {
                echo "Running Terraform to provision namespaces..."
                dir("terraform") {
                    sh """
                        terraform init -input=false
                        terraform plan -input=false -out=tfplan
                        terraform apply -input=false tfplan
                    """
                }
                echo "Namespaces provisioned."
            }
        }

        // STAGE 4 — Configure Namespaces (Ansible)

        stage("Configure") {
            steps {
                echo "Running Ansible to configure namespaces..."
                dir("ansible") {
                    sh """
                        ansible-playbook \\
                            -i inventory/hosts.yml \\
                            playbook.yml
                    """
                }

                archiveArtifacts artifacts: "ansible-audit.log", allowEmptyArchive: false
                echo "Namespaces configured."
            }
        }

        // STAGE 5 — Deploy to Staging

        stage("Deploy Staging") {
            steps {
                echo "Deploying to ${STAGING_NS}..."
                sh """
                    # ConfigMap must exist before the Deployment starts
                    kubectl apply -f k8s/configmap-staging.yaml -n ${STAGING_NS}

                    # Deploy the application
                    kubectl apply -f k8s/deployment.yaml -n ${STAGING_NS}

                    # Expose via Service and Ingress
                    kubectl apply -f k8s/service.yaml   -n ${STAGING_NS}
                    kubectl apply -f k8s/ingress.yaml   -n ${STAGING_NS}

                    # Wait for the rollout to complete before smoke testing
                    # This blocks until all pods are Running and Ready
                    kubectl rollout status deployment/${APP_NAME} \\
                        -n ${STAGING_NS} \\
                        --timeout=120s
                """
                echo "Staging deployment complete."
            }
        }

        stage("Monitor") {
            steps {
                sh "chmod +x monitoring/error_rate.sh"
                sh "./monitoring/error_rate.sh ${PRODUCTION_NS} 200 5"
                archiveArtifacts artifacts: "monitoring/monitoring.log"
            }
        }

        // STAGE 6 — Smoke Test

        stage("Smoke Test") {
            steps {
                echo "Running smoke test against staging..."
                script {
                    def smokeTestPassed = false
                    def maxAttempts    = 5
                    def waitSeconds    = 10

                    for (int i = 1; i <= maxAttempts; i++) {
                        echo "Smoke test attempt ${i} of ${maxAttempts}..."

                        def response = sh(
                            script: """
                                curl --silent --output /dev/null \\
                                     --write-out "%{http_code}" \\
                                     --max-time 10 \\
                                     http://${STAGING_HOST}/health
                            """,
                            returnStdout: true
                        ).trim()

                        echo "GET /health returned: HTTP ${response}"

                        if (response == "200") {
                            smokeTestPassed = true
                            echo "Smoke test PASSED — staging is healthy."
                            break
                        }

                        if (i < maxAttempts) {
                            echo "Waiting ${waitSeconds}s before next attempt..."
                            sleep(waitSeconds)
                        }
                    }

                    if (!smokeTestPassed) {
                        sh """
                            echo '--- Pod logs at smoke test failure ---'
                            kubectl logs -l app=${APP_NAME} \\
                                -n ${STAGING_NS} \\
                                --tail=50 || true
                        """
                        error("Smoke test FAILED after ${maxAttempts} attempts. Production deploy blocked.")
                    }
                }
            }
        }

        // STAGE 7 — Approval Gate

        stage("Approval Gate") {
            steps {
                script {
                    echo "Smoke test passed. Waiting for production deploy approval..."
                    timeout(time: 30, unit: "MINUTES") {
                        input(
                            message: """
                                Staging smoke test passed.
                                Commit: ${env.GIT_COMMIT_SHORT}
                                Build:  ${BUILD_NUMBER}

                                Approve deployment to production?
                            """,
                            ok: "Deploy to Production"
                        )
                    }
                }
            }
        }

        // STAGE 8 — Deploy to Production

        stage("Deploy Production") {
            steps {
                echo "Deploying to ${PRODUCTION_NS}..."
                sh """
                    kubectl apply -f k8s/configmap-production.yaml -n ${PRODUCTION_NS}
                    kubectl apply -f k8s/deployment.yaml           -n ${PRODUCTION_NS}
                    kubectl apply -f k8s/service.yaml              -n ${PRODUCTION_NS}
                    kubectl apply -f k8s/ingress.yaml              -n ${PRODUCTION_NS}

                    kubectl rollout status deployment/${APP_NAME} \\
                        -n ${PRODUCTION_NS} \\
                        --timeout=120s
                """
                echo "Production deployment complete."
            }
        }

        // STAGE 9 — Verify Production

        stage("Verify Production") {
            steps {
                echo "Verifying production deployment..."
                sh """
                    # Confirm rollout status
                    kubectl rollout status deployment/${APP_NAME} \\
                        -n ${PRODUCTION_NS}

                    # Print both ConfigMaps side by side — proves different DB_HOST
                    echo '--- Staging ConfigMap ---'
                    kubectl get configmap orflow-config \\
                        -n ${STAGING_NS} -o yaml

                    echo '--- Production ConfigMap ---'
                    kubectl get configmap orflow-config \\
                        -n ${PRODUCTION_NS} -o yaml

                    # Quick health check against production
                    curl --silent --fail \\
                         http://${PRODUCTION_HOST}/health || true
                """
                echo "Production verified."
            }
        }
    }

    // Post-pipeline actions
    post {

        success {
            echo """
                ================================================
                Pipeline completed successfully.
                Build   : ${BUILD_NUMBER}
                Commit  : ${env.GIT_COMMIT_SHORT}
                Staging : http://${STAGING_HOST}/health
                Prod    : http://${PRODUCTION_HOST}/health
                ================================================
            """
        }

        failure {
            echo """
                ================================================
                Pipeline FAILED at stage: ${env.STAGE_NAME}
                Build  : ${BUILD_NUMBER}
                Commit : ${env.GIT_COMMIT_SHORT}
                Check the logs above for the failure reason.
                Production was NOT touched if failure was before the approval gate.
                ================================================
            """
            
            sh """
                kubectl get events -n ${STAGING_NS} \\
                    --sort-by='.lastTimestamp' | tail -20 || true
            """
        }

        always {
            sh "rm -f terraform/tfplan || true"
            echo "Pipeline finished. Build: ${BUILD_NUMBER}"
        }
    }
}