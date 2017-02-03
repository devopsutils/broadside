require 'spec_helper'

describe Broadside::EcsDeploy do
  include_context 'deploy configuration'
  include_context 'ecs stubs'

  let(:family) { deploy.target.family }
  let(:target) { Broadside::Target.new(test_target_name, test_target_config) }
  let(:local_deploy_config) { {} }
  let(:deploy) { described_class.new(test_target_name, local_deploy_config.merge(tag: 'tag_the_bag')) }
  let(:desired_count) { 2 }
  let(:cpu) { 1 }
  let(:memory) { 2000 }
  let(:service_config) do
    {
      desired_count: desired_count,
      deployment_configuration: {
        minimum_healthy_percent: 40,
      }
    }
  end

  context 'bootstrap' do
    it 'fails without task_definition_config' do
      expect { deploy.bootstrap }.to raise_error(/No first task definition and no :task_definition_config/)
    end

    context 'with an existing task definition' do
      include_context 'with a task_definition'

      it 'fails without service_config' do
        expect { deploy.bootstrap }.to raise_error(/Service doesn't exist and no :service_config/)
      end

      context 'with a service_config' do
        let(:local_target_config) { { service_config: service_config } }

        it 'sets up the service' do
          expect(Broadside::EcsManager).to receive(:create_service).with(cluster, family, service_config)
          expect { deploy.bootstrap }.to_not raise_error
        end
      end

      context 'with an existing service' do
        include_context 'with a running service'

        it 'succeeds' do
          expect { deploy.bootstrap }.to_not raise_error
        end

        context 'and some configured bootstrap commands' do
          let(:commands) { [%w(foo bar baz)] }
          let(:local_target_config) { { bootstrap_commands: commands } }

          it 'runs bootstrap commands' do
            expect(deploy).to receive(:run_commands).with(commands, started_by: 'bootstrap')
            deploy.bootstrap
          end
        end
      end
    end
  end

  context 'deploy' do
    it 'fails without an existing service' do
      expect { deploy.short }.to raise_error(/No service for '#{deploy.target.family}'!/)
    end

    context 'with an existing service' do
      include_context 'with a running service'

      it 'fails without an existing task_definition' do
        expect { deploy.short }.to raise_error(/No task definition for/)
      end

      context 'with an existing task definition' do
        include_context 'with a task_definition'

        it 'short deploy does not fail' do
          expect { deploy.short }.to_not raise_error
        end

        context 'updating service and task definitions' do
          let(:task_definition_config) do
            {
              container_definitions: [
                {
                  cpu: cpu,
                  memory: memory
                }
              ]
            }
          end
          let(:local_target_config) do
            {
              task_definition_config: task_definition_config,
              service_config: service_config
            }
          end

          it 'should reconfigure the task definition' do
            deploy.short

            register_requests = api_request_log.select { |cmd| cmd.keys.first == :register_task_definition }
            expect(register_requests.size).to eq(1)
            expect(register_requests.first.values.first[:container_definitions].first[:cpu]).to eq(cpu)
            expect(register_requests.first.values.first[:container_definitions].first[:memory]).to eq(memory)
          end

          it 'should reconfigure the service definition' do
            deploy.short

            service_requests = api_request_log.select { |cmd| cmd.keys.first == :update_service }
            expect(service_requests.first.values.first[:desired_count]).to eq(desired_count)
          end

          context 'full deploy' do
            let(:predeploy_commands) { [%w(x y z), %w(a b c)] }
            let(:local_target_config) { { predeploy_commands: predeploy_commands } }

            it 'should run predeploy_commands' do
              expect(deploy).to receive(:run_commands).with(predeploy_commands, started_by: 'predeploy')
              deploy.full
            end
          end
        end

        it 'can rollback' do
          deploy.rollback
          expect(api_request_methods.include?(:deregister_task_definition)).to be true
          expect(api_request_methods.include?(:update_service)).to be true
        end
      end
    end
  end

  context 'bash' do
    it 'fails without a running service' do
      expect { deploy.bash }.to raise_error(Broadside::Error, /No task definition for '#{family}'/)
    end

    context 'with a task definition and service in place' do
      include_context 'with a running service'
      include_context 'with a task_definition'

      it 'fails without a running task' do
        expect { deploy.bash }.to raise_error /No running tasks found for/
      end

      context 'with a running task' do
        let(:task_arn) { 'some_task_arn' }
        let(:container_arn) { 'some_container_arn' }
        let(:instance_id) { 'i-xxxxxxxx' }
        let(:ip) { '123.123.123.123' }

        before(:each) do
          ecs_stub.stub_responses(:list_tasks, task_arns: [task_arn])
          ecs_stub.stub_responses(:describe_tasks, tasks: [{ container_instance_arn: container_arn }])
          ecs_stub.stub_responses(:describe_container_instances, container_instances: [{ ec2_instance_id: instance_id }])
          ec2_stub.stub_responses(:describe_instances, reservations: [ instances: [{ private_ip_address: ip }]])
        end

        it 'executes correct system command' do
          expect(deploy).to receive(:exec).with("ssh -o StrictHostKeyChecking=no -t -t #{user}@#{ip} 'docker exec -i -t `docker ps -n 1 --quiet --filter name=#{family}` bash'")
          expect { deploy.bash }.to_not raise_error
          expect(api_request_log).to eq([
            { list_task_definitions: { family_prefix: family } },
            { describe_services: { cluster: cluster, services: [family] } },
            { list_tasks: { cluster: cluster, family: family } },
            { describe_tasks: { cluster: cluster, tasks: [task_arn] } },
            { describe_container_instances: { cluster: cluster, container_instances: [container_arn] } },
            { describe_instances: { instance_ids: [instance_id] } }
          ])
        end
      end
    end
  end

  context 'run' do
    let(:local_deploy_config) { { command: %w(run some command) } }

    it 'fails without a task definition' do
      expect { deploy.run }.to raise_error(/No task definition for /)
    end

    context 'with a task_definition' do
      include_context 'with a task_definition'

      before do
        ecs_stub.stub_responses(:run_task, tasks: [task_arn: 'task_arn'])
      end

      it 'runs' do
        expect(ecs_stub).to receive(:wait_until)
        expect(deploy).to receive(:get_container_logs)
        expect(Broadside::EcsManager).to receive(:get_task_exit_code).and_return(0)
        expect { deploy.run }.to_not raise_error
      end
    end
  end
end