require './test/api_helper'
require './test/fixtures/fake_curricula'
require 'mocha/setup'

class AssignmentsApiTest < Minitest::Test
  include Rack::Test::Methods
  include DBCleaner

  def app
    ExercismAPI
  end

  attr_reader :alice, :curriculum
  def setup
    super
    @alice = User.create(username: 'alice', github_id: 1, current: {'ruby' => 'one', 'go' => 'two'}, completed: {'go' => ['one']})
    @curriculum = Curriculum.new('./test/fixtures')
    @curriculum.add FakeRubyCurriculum.new
    @curriculum.add FakeGoCurriculum.new
    @curriculum.add FakeScalaCurriculum.new
    Exercism.instance_variable_set(:@trails, nil)
    Exercism.instance_variable_set(:@languages, nil)
  end

  def teardown
    super
    Exercism.instance_variable_set(:@trails, nil)
    Exercism.instance_variable_set(:@languages, nil)
  end

  def test_cannot_fetch_exercise_in_nonexistent_language
    Exercism.stub(:current_curriculum, curriculum) do
      get '/assignments/nosuch/one'
      assert_equal 400, last_response.status
      assert_match /sorry/i, JSON.parse(last_response.body)['error']
    end
  end

  def test_cannot_fetch_nonexistent_exercise
    Exercism.stub(:current_curriculum, curriculum) do
      get '/assignments/ruby/million'
      assert_equal 400, last_response.status
      assert_match /sorry/i, JSON.parse(last_response.body)['error']
    end
  end

  def test_fetch_exercise
    Exercism.stub(:current_curriculum, curriculum) do
      get '/assignments/ruby/one'
      assert_equal 200, last_response.status
      options = {format: :json, name: 'fetch_specific_exercise'}
      Approvals.verify(last_response.body, options)
    end
  end

  def test_api_delivers_current_and_upcoming_assignments_for_each_track
    Submission.create(user: alice, language: 'go', slug: 'one', code: 'CODE', state: 'done')
    Submission.create(user: alice, language: 'go', slug: 'two', code: 'CODE', state: 'pending')
    Submission.create(user: alice, language: 'ruby', slug: 'one', code: 'CODE', state: 'pending')

    Exercism.stub(:current_curriculum, curriculum) do

      get '/user/assignments/current', {key: alice.key}

      output = last_response.body
      options = {format: :json, :name => 'api_current_assignment_data'}
      Approvals.verify(output, options)
    end
  end

  def test_api_complains_if_no_key_is_submitted
    get '/user/assignments/current'
    assert_equal 401, last_response.status
  end

  def test_api_complains_if_no_key_is_submitted_for_completed_assignments
    get '/user/assignments/completed'
    assert_equal 401, last_response.status
  end

  def test_api_accepts_submission_attempt
    Exercism.stub(:current_curriculum, curriculum) do
      Notify.stub(:everyone, nil) do
        post '/user/assignments', {key: alice.key, code: 'THE CODE', path: 'one/code.rb'}.to_json
      end

      submission = Submission.first
      ex = Exercise.new('ruby', 'one')
      assert_equal ex, submission.exercise
      assert_equal 201, last_response.status

      options = {format: :json, :name => 'api_submission_accepted'}
      Approvals.verify(last_response.body, options)
    end
  end

  def test_api_accepts_submission_on_completed_exercise
    Exercism.stub(:current_curriculum, curriculum) do
      Notify.stub(:everyone, nil) do
        post '/user/assignments', {key: alice.key, code: 'THE CODE', path: 'one/code.go'}.to_json
      end

      submission = Submission.first
      ex = Exercise.new('go', 'one')
      assert_equal ex, submission.exercise
      assert_equal 201, last_response.status

      options = {format: :json, :name => 'api_submission_accepted_on_completed'}
      Approvals.verify(last_response.body, options)
    end
  end

  def test_api_rejects_submission_on_nonexistent_exercise
    Exercism.stub(:current_curriculum, curriculum) do
      Notify.stub(:everyone, nil) do
        post '/user/assignments', {key: alice.key, code: 'THE CODE', path: 'five/code.rb'}.to_json
      end

      assert_equal 400, last_response.status

      options = {format: :json, :name => 'reject_nonexistent_exercise'}
      Approvals.verify(last_response.body, options)
    end
  end

  def test_fetch_at_the_end_of_trail
    Exercism.stub(:current_curriculum, curriculum) do
      bob = User.create(github_id: 2, current: {'ruby' => 'two'})
      trail = Exercism.current_curriculum.in('ruby')
      bob.complete! trail.exercises.last
      get '/user/assignments/current', {key: bob.key}
      assert_equal 200, last_response.status
    end
  end

  def test_fetch_demo
    Exercism.stub(:current_curriculum, curriculum) do
      get '/assignments/demo'
      assert_equal 200, last_response.status

      options = {format: :json, :name => 'api_demo'}
      Approvals.verify(last_response.body, options)
    end
  end

  def test_completed_sends_back_empty_list_for_new_user
    new_user = User.create(github_id: 2)

    get '/user/assignments/completed', {key: new_user.key}

    assert_equal({"assignments" => {}}, JSON::parse(last_response.body))
  end

  def test_completed_returns_the_names_of_completed_assignments
    Exercism.stub(:current_curriculum, curriculum) do
      user = User.create(github_id: 2)
      Submission.create(user: user, code: 'CODE', state: 'done', language: 'ruby', slug: 'one')
      Submission.create(user: user, code: 'CODE', state: 'done', language: 'ruby', slug: 'two')
      Submission.create(user: user, code: 'CODE', state: 'done', language: 'python', slug: 'one')

      get '/user/assignments/completed', {key: user.key}

      assert_equal({"assignments" => {"ruby" => ['one', 'two'], 'python' => ['one']}}, JSON::parse(last_response.body))
    end
  end

  def test_peek_is_deprecated
    get '/user/assignments/next'
    assert_equal 410, last_response.status
  end

  def test_notify_team_members_about_submission
    bob = User.create username: 'bob', github_id: -2
    charlie = User.create username: 'charlie', github_id: -3
    dave = User.create username: 'dave', github_id: -4
    eve = User.create username: 'eve', github_id: -5

    Submission.create(language: 'ruby', slug: 'bob', code: 'CODE', user: charlie)
    Submission.create(language: 'ruby', slug: 'bob', code: 'CODE', user: dave, state: 'done')

    Team.create(slug: 'team1', members: [bob, charlie], creator: alice)
    Team.create(slug: 'team2', members: [bob, dave, eve], creator: alice)

    post '/user/assignments', {key: bob.key, code: 'THE CODE', path: 'bob/code.rb'}.to_json
    assert_equal 201, last_response.status

    [alice, charlie, dave].each do |user|
      assert_equal 1, user.reload.notifications.count, "Notify #{user.username} failed"
    end

    assert_equal 0, eve.reload.notifications.count
  end

  def test_api_rejects_duplicates
    Exercism.stub(:current_curriculum, curriculum) do
      Attempt.new(alice, 'THE CODE', 'one/code.rb').save
      Notify.stub(:everyone, nil) do
        post '/user/assignments', {key: alice.key, code: 'THE CODE', path: 'one/code.rb'}.to_json
      end

      response_error = JSON.parse(last_response.body)['error']

      assert_equal 400, last_response.status
      assert_equal "This attempt is a duplicate of the previous one.", response_error
    end
  end

  def test_unsubmit_success
    Exercism.stub(:current_curriculum, curriculum) do
      unsubmit_object = stub()

      Unsubmit.expects(:new).with(alice).returns(unsubmit_object)
      unsubmit_object.expects(:unsubmit)

      delete '/user/assignments', {key: alice.key}
      assert_equal 204, last_response.status
    end
  end

  def test_unsubmit_fails_no_submission
    Exercism.stub(:current_curriculum, curriculum) do
      unsubmit_object = stub()

      Unsubmit.expects(:new).with(alice).returns(unsubmit_object)
      unsubmit_object.expects(:unsubmit).raises(Unsubmit::NothingToUnsubmit.new)

      delete '/user/assignments', {key: alice.key}
      assert_equal 404, last_response.status
    end
  end

  def test_unsubmit_fails_with_nits
    Exercism.stub(:current_curriculum, curriculum) do
      unsubmit_object = stub()

      Unsubmit.expects(:new).with(alice).returns(unsubmit_object)
      unsubmit_object.expects(:unsubmit).raises(Unsubmit::SubmissionHasNits.new)

      delete '/user/assignments', {key: alice.key}
      assert_equal 403, last_response.status
    end
  end

  def test_unsubmit_fails_when_already_done
    Exercism.stub(:current_curriculum, curriculum) do
      unsubmit_object = stub()

      Unsubmit.expects(:new).with(alice).returns(unsubmit_object)
      unsubmit_object.expects(:unsubmit).raises(Unsubmit::SubmissionDone.new)

      delete '/user/assignments', {key: alice.key}
      assert_equal 403, last_response.status
    end
  end

  def test_unsubmit_fails_too_old
    Exercism.stub(:current_curriculum, curriculum) do
      unsubmit_object = stub()

      Unsubmit.expects(:new).with(alice).returns(unsubmit_object)
      unsubmit_object.expects(:unsubmit).raises(Unsubmit::SubmissionTooOld.new)

      delete '/user/assignments', {key: alice.key}
      assert_equal 403, last_response.status
    end
  end

end
