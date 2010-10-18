require 'spec_helper'

describe "plsql-spec" do

  before(:all) do
    @root_dir = destination_root
    FileUtils.rm_rf(@root_dir)
    FileUtils.mkdir_p(@root_dir)
  end

  def run_cli(*args)
    Dir.chdir(@root_dir) do
      @stdout = capture(:stdout) do
        begin
          PLSQL::Spec::CLI.start(args)
        rescue SystemExit => e
          @exit_status = e.status
        end
      end
    end
  end

  def create_database_yml
    content = "default:\n" <<
    "  username: #{DATABASE_USER}\n" <<
    "  password: #{DATABASE_PASSWORD}\n" <<
    "  database: #{DATABASE_NAME}\n"
    content << "  host:     #{DATABASE_HOST}\n" if defined?(DATABASE_HOST)
    content << "  port:     #{DATABASE_PORT}\n" if defined?(DATABASE_PORT)
    File.open(File.join(@root_dir, 'spec/database.yml'), 'w') do |file|
      file.write(content)
    end
  end

  def inject_local_load_path
    spec_helper_file = File.join(@root_dir, 'spec/spec_helper.rb')
    content = File.read(spec_helper_file)
    content.gsub! 'require "ruby-plsql-spec"',
      "$:.unshift(File.expand_path('../../../../lib', __FILE__))\nrequire \"ruby-plsql-spec\""
    File.open(spec_helper_file, 'w') do |file|
      file.write(content)
    end
  end

  def create_test(name, string)
    file_content = <<-EOS
require 'spec_helper'

describe "test" do
  it #{name.inspect} do
    #{string}
  end
end
EOS
    Dir.chdir(@root_dir) do
      File.open('spec/test_spec.rb', 'w') do |file|
        file << file_content
      end
    end
  end

  describe "init" do
    before(:all) do
      run_cli('init')
    end

    it "should create spec subdirectory" do
      File.directory?(@root_dir + '/spec').should be_true
    end

    it "should create spec_helper.rb" do
      File.file?(@root_dir + '/spec/spec_helper.rb').should be_true
    end

    it "should create database.yml" do
      File.file?(@root_dir + '/spec/database.yml').should be_true
    end

    it "should create helpers/inspect_helpers.rb" do
      File.file?(@root_dir + '/spec/helpers/inspect_helpers.rb').should be_true
    end

    it "should create factories subdirectory" do
      File.directory?(@root_dir + '/spec/factories').should be_true
    end

  end

  describe "run" do
    before(:all) do
      run_cli('init')
      create_database_yml
      inject_local_load_path
    end

    describe "successful tests" do
      before(:all) do
        create_test 'SYSDATE should not be NULL',
          'plsql.sysdate.should_not == NULL'
        run_cli('run')
      end

      it "should report zero failures" do
        @stdout.should =~ / 0 failures/
      end

      it "should not return failing exit status" do
        @exit_status.should be_nil
      end
    end

    describe "failing tests" do
      before(:all) do
        create_test 'SYSDATE should be NULL',
          'plsql.sysdate.should == NULL'
        run_cli('run')
      end

      it "should report failures" do
        @stdout.should =~ / 1 failure/
      end

      it "should return failing exit status" do
        @exit_status.should == 1
      end
    end

    describe "specified files" do
      before(:all) do
        create_test 'SYSDATE should not be NULL',
          'plsql.sysdate.should_not == NULL'
      end

      it "should report one file examples" do
        run_cli('run', 'spec/test_spec.rb')
        @stdout.should =~ /1 example/
      end

      it "should report two files examples" do
        run_cli('run', 'spec/test_spec.rb', 'spec/test_spec.rb')
        @stdout.should =~ /2 examples/
      end
    end

    describe "with coverage" do
      before(:all) do
        plsql.connect! CONNECTION_PARAMS
        plsql.execute <<-SQL
          CREATE OR REPLACE FUNCTION test_profiler RETURN VARCHAR2 IS
          BEGIN
            RETURN 'test_profiler';
          EXCEPTION
            WHEN OTHERS THEN
              RETURN 'others';
          END;
        SQL
        create_test 'shoud test coverage',
          'plsql.test_profiler.should == "test_profiler"'
        @index_file = File.join(@root_dir, 'coverage/index.html')
        @details_file = File.join(@root_dir, "coverage/#{DATABASE_USER.upcase}-TEST_PROFILER.html")
      end

      after(:all) do
        plsql.execute "DROP FUNCTION test_profiler" rescue nil
      end

      before(:each) do
        FileUtils.rm_rf File.join(@root_dir, 'coverage')
      end

      after(:each) do
        %w(PLSQL_COVERAGE PLSQL_COVERAGE_IGNORE_SCHEMAS PLSQL_COVERAGE_LIKE).each do |variable|
          ENV.delete variable
        end
      end

      it "should report zero failures" do
        run_cli('run', '--coverage')
        @stdout.should =~ / 0 failures/
      end

      it "should generate coverage reports" do
        run_cli('run', '--coverage')
        File.file?(@index_file).should be_true
        File.file?(@details_file).should be_true
      end

      it "should generate coverage reports in specified directory" do
        run_cli('run', '--coverage', 'plsql_coverage')
        File.file?(@index_file.gsub('coverage', 'plsql_coverage')).should be_true
        File.file?(@details_file.gsub('coverage', 'plsql_coverage')).should be_true
      end

      it "should not generate coverage report for ignored schema" do
        run_cli('run', '--coverage', '--ignore_schemas', DATABASE_USER)
        File.file?(@details_file).should be_false
      end

      it "should generate coverage report for objects matching like condition" do
        run_cli('run', '--coverage', '--like', "#{DATABASE_USER}.%")
        File.file?(@details_file).should be_true
      end

      it "should not generate coverage report for objects not matching like condition" do
        run_cli('run', '--coverage', '--like', "#{DATABASE_USER}.aaa%")
        File.file?(@details_file).should be_false
      end

    end

    describe "with dbms_output" do
      before(:all) do
        plsql.connect! CONNECTION_PARAMS
        plsql.execute <<-SQL
          CREATE OR REPLACE PROCEDURE test_dbms_output IS
          BEGIN
            DBMS_OUTPUT.PUT_LINE('test_dbms_output');
          END;
        SQL
        create_test 'shoud test dbms_output',
          'plsql.test_dbms_output.should be_nil'
      end

      after(:all) do
        plsql.execute "DROP PROCEDURE test_dbms_output" rescue nil
      end

      after(:each) do
        ENV.delete 'PLSQL_DBMS_OUTPUT'
      end

      it "should show DBMS_OUTPUT in standard output" do
        run_cli('run', '--dbms_output')
        @stdout.should =~ /DBMS_OUTPUT: test_dbms_output/
      end

      it "should not show DBMS_OUTPUT without specifying option" do
        run_cli('run')
        @stdout.should_not =~ /DBMS_OUTPUT: test_dbms_output/
      end

    end

    describe "with html output" do
      before(:all) do
        create_test 'SYSDATE should not be NULL',
          'plsql.sysdate.should_not == NULL'
        @default_html_file = File.join(@root_dir, 'test-results.html')
        @custom_file_name = 'custom-results.html'
        @custom_html_file = File.join(@root_dir, @custom_file_name)
      end

      def delete_html_output_files
        FileUtils.rm_rf @default_html_file
        FileUtils.rm_rf @custom_html_file
      end

      before(:each) do
        delete_html_output_files
      end

      after(:all) do
        delete_html_output_files
      end

      it "should create default report file" do
        run_cli('run', '--html')
        File.read(@default_html_file).should =~ / 0 failures/
      end

      it "should create specified report file" do
        run_cli('run', '--html', @custom_file_name)
        File.read(@custom_html_file).should =~ / 0 failures/
      end

    end

  end

  describe "version" do
    before(:all) do
      run_cli('-v')
    end

    it "should show ruby-plsql-spec version" do
      @stdout.should =~ /ruby-plsql-spec\s+#{PLSQL::Spec::VERSION.gsub('.','\.')}/
    end

    it "should show ruby-plsql version" do
      @stdout.should =~ /ruby-plsql\s+#{PLSQL::VERSION.gsub('.','\.')}/
    end

    it "should show rspec version" do
      @stdout.should =~ /rspec\s+#{::Spec::VERSION::STRING.gsub('.','\.')}/
    end

  end
end
